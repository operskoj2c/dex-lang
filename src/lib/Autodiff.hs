-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS_GHC -w #-} -- XXX: Disable once fixed

module Autodiff (linearize, transposeMap) where

import Control.Applicative
import Control.Monad
import Control.Monad.Reader
import Data.List (elemIndex)

import Type
import Env
import Syntax
import Cat
import PPrint
import Embed

import Data.Text.Prettyprint.Doc

-- === linearization ===

-- `DerivWrt` holds the (out-expr) variables that we're differentiating with
-- respect to (including refs but not regions). `Tangents` holds the tangent
-- values and the region variables that are arguments to the linearized
-- function.
-- TODO: use something with O(1) lookups.
type DerivWrt = ([Var], EffectRow)
type Tangents = ([Atom], [Name])

type PrimalM  = ReaderT DerivWrt Embed
type TangentM = ReaderT Tangents Embed
newtype LinA a = LinA { runLinA :: PrimalM (a, TangentM a) }

linearize :: Scope -> Atom -> Atom
linearize scope (Lam (Abs b (_, block))) = fst $ flip runEmbed scope $ do
  buildLam b PureArrow $ \x@(Var v) -> do
    (y, yt) <- flip runReaderT ([v], Pure) $ runLinA $ linearizeBlock (b@>x) block
    -- TODO: check linearity
    fLin <- buildLam b LinArrow $ \xt -> runReaderT yt ([xt], [])
    fLinChecked <- checkEmbed fLin
    return $ PairVal y fLinChecked

linearizeBlock :: SubstEnv -> Block -> LinA Atom
linearizeBlock env (Block decls result) = case decls of
  [] -> linearizeExpr env result
  Let _ b bound : rest -> LinA $ do
    -- TODO: handle discrete case specially.
    (x, boundLin) <- runLinA $ linearizeExpr env bound
    ~x'@(Var v) <- emit $ Atom x
    (ans, bodyLin) <- extendWrt ([v], Pure) $ runLinA $
                        linearizeBlock (env <> b@>x') body
    return (ans, do t <- boundLin
                    extendR ([t], []) bodyLin)
    where body = Block rest result

-- TODO: curried linear functions somehow?
tangentFunAsLambda :: LinA Atom -> PrimalM Atom
tangentFunAsLambda m = do
  (ans, tanFun) <- runLinA m
  (vs, EffectRow effs _) <- ask
  let hs = map ((:>TyKind) . snd) effs
  liftM (PairVal ans) $ lift $ do
    buildNestedLam hs $ \hVals -> do
      let hVarNames = map (\(Var (v:>_)) -> v) hVals
      let effs' = zipWith (\(effName, _) v -> (effName, v)) effs hVarNames
      -- want to use tangents here, not the original binders
      let regionMap = newEnv (map ((:>()) . snd) effs) hVals
      let vs' = map (fmap (tangentRefRegion regionMap)) vs
      buildNestedLam vs' $ \xs ->
        buildLam ("dummy":>UnitTy) (PlainArrow $ EffectRow effs' Nothing) $ \_ ->
          runReaderT tanFun (xs, hVarNames)

-- This doesn't work if we have references inside pairs, tables etc.
-- TODO: something more general and cleaner.
tangentRefRegion :: Env Atom -> Type -> Type
tangentRefRegion subst ty = case ty of
  RefTy ~(Var h) a -> RefTy (subst ! h) $ tangentType a
  _ -> tangentType ty

buildNestedLam :: MonadEmbed m => [Binder] -> ([Atom] -> m Atom) -> m Atom
buildNestedLam [] f = f []
buildNestedLam (b:bs) f =
  buildLam b PureArrow $ \x -> buildNestedLam bs $ \xs -> f (x:xs)

linearizeExpr :: SubstEnv -> Expr -> LinA Atom
linearizeExpr env expr = case expr of
  -- _ | hasDiscreteType expr -> LinA $ do
  --   ans <- substEmbed expr >>= emit
  --   return $ withZeroTangent ans
  Hof  e -> linearizeHof env e
  _ -> LinA $ do
    expr' <- substEmbed env expr
    runLinA $ case expr' of
      App x i | isTabTy (getType x) -> LinA $ do
        (i', _)  <- runLinA $ linearizeAtom i
        (x', tx) <- runLinA $ linearizeAtom x
        ans <- emit $ App x' i'
        return (ans, do tx' <- tx
                        emit $ App tx' i')
      Op   e -> linearizeOp   e
      Atom e -> linearizeAtom e
      _ -> error $ "Not implemented: " ++ pprint expr


linearizeOp :: Op -> LinA Atom
linearizeOp op = case fmap linearizeAtom op of
  ScalarUnOp  FNeg x     ->     liftA  (ScalarUnOp  FNeg) x     `bindLin` emitOp
  ScalarBinOp FAdd x1 x2 ->     liftA2 (ScalarBinOp FAdd) x1 x2 `bindLin` emitOp
  ScalarBinOp FSub x1 x2 ->     liftA2 (ScalarBinOp FSub) x1 x2 `bindLin` emitOp
  ScalarBinOp FMul x1 x2 -> tensLiftA2 (ScalarBinOp FMul) x1 x2
  ScalarBinOp FDiv x y -> LinA $ do
    (x', tx) <- runLinA x
    (y', ty) <- runLinA y
    ans <- div' x' y'
    return (ans, do tx' <- tx
                    ty' <- ty
                    linearizedDiv x' y' tx' ty')
  PrimEffect refArg m ->
    liftA2 PrimEffect refArg
      (case m of
         MAsk    -> pure MAsk
         MTell x -> liftA MTell x
         _       -> error "Not implemented") `bindLin` emitOp
  Fst x -> liftA Fst x `bindLin` emitOp
  Snd x -> liftA Snd x `bindLin` emitOp
  _ -> error $ "not implemented: " ++ pprint op

linearizeHof :: SubstEnv -> Hof -> LinA Atom
linearizeHof env hof = case hof of
  For d (Lam (Abs i (_, body))) -> LinA $ do
    i' <- mapM (substEmbed env) i
    (ans, linTab) <- (unzipTab =<<) $ buildFor d i' $ \i'' ->
       tangentFunAsLambda $ linearizeBlock (env <> i@>i'') body
    return (ans, buildFor d i' $ \i'' -> do
                   lin <- app linTab i''
                   applyLinToTangents lin)
  RunWriter lam -> LinA $ do
    lam' <- linearizeEffectFun Writer env lam
    (ansLin, w) <- fromPair =<< emit (Hof $ RunWriter lam')
    (ans, lin) <- fromPair ansLin
    let (BinaryFunTy _ (_:>RefTy _ wTy) _ _) = getType lam'
    let lin' = emitRunWriter "w" wTy $ \ref@(Var (_:> RefTy (Var (h:>_)) _)) -> do
                 extendR ([ref], [h]) $ applyLinToTangents lin
    return (PairVal ans w, lin')


applyLinToTangents :: Atom -> TangentM Atom
applyLinToTangents f = do
  (tangents, hs) <- ask
  let hs' = map (Var . (:>TyKind)) hs
  let args = hs' ++ tangents ++ [UnitVal]
  naryApp f args

linearizeEffectFun :: EffectName -> SubstEnv -> Atom -> PrimalM Atom
linearizeEffectFun effName env (BinaryFunVal h ref eff body) = do
  h' <- mapM (substEmbed env) h
  buildLam h' PureArrow $ \h''@(Var hVar) -> do
    let env' = env <> h@>h''
    eff' <- substEmbed env' eff
    ref' <- mapM (substEmbed env') ref
    buildLam ref' (PlainArrow eff') $ \ref''@(Var refVar) ->
      extendWrt ([refVar], EffectRow [(effName, varName hVar)] Nothing) $
        tangentFunAsLambda $ linearizeBlock (env' <> ref@>ref'') body

linearizedDiv :: Atom -> Atom -> Atom -> Atom -> TangentM Atom
linearizedDiv x y tx ty = do
  tx'  <- div' tx y
  ty'  <- mul ty x
  ySq  <- mul y y
  ty'' <- div' ty' ySq >>= neg
  add tx' ty''

linearizePrimCon :: Con -> LinA Atom
linearizePrimCon con = case con of
  Lit _    -> LinA $ return (withZeroTangent x)  where x = Con con
  --AFor _ _ -> LinA $ return (withZeroTangent x)  where x = Con con
  PairCon x y -> liftA2 PairVal (linearizeAtom x) (linearizeAtom y)
  _ -> error $ "not implemented: " ++ pprint con

linearizeAtom :: Atom -> LinA Atom
-- linearizeAtom atom | hasDiscreteType atom =
--   LinA $ liftM withZeroTangent $ substEmbed atom
linearizeAtom atom = case atom of
  Var v -> LinA $ do
    derivWrt <- asks (map varName . fst)  -- TODO: something more efficient
    case elemIndex (varName v) derivWrt of
      Nothing -> return $ withZeroTangent atom
      Just i -> return (atom, asks $ (!!i) . fst)
  Con con -> linearizePrimCon con
  _ -> error "Not implemented"

withZeroTangent :: Atom -> (Atom, TangentM Atom)
withZeroTangent x = (x, zeroAt (tangentType (getType x)))

tangentType :: Type -> Type
tangentType (TabTy n a) = TabTy n (tangentType a)
tangentType (TC con) = case con of
  BaseType (Scalar RealType) -> TC con
  BaseType (Vector RealType) -> TC con
  BaseType   _               -> UnitTy
  IntRange   _ _             -> UnitTy
  IndexRange _ _ _           -> UnitTy
  UnitType                   -> UnitTy
  PairType a b               -> PairTy (tangentType a) (tangentType b)
  _           -> error $ "Can't differentiate wrt type " ++ pprint con
tangentType ty = error $ "Can't differentiate wrt type " ++ pprint ty

-- TODO: consider effects!
hasDiscreteType :: HasType e => e -> Bool
hasDiscreteType expr = isSingletonType tangentTy
  where tangentTy = tangentType $ getType expr

tensLiftA2 :: (HasVars a, HasVars b)
           => (a -> b -> Op) -> LinA a -> LinA b -> LinA Atom
tensLiftA2 f (LinA m1) (LinA m2) = LinA $ do
  (x1, mt1) <- m1
  (x2, mt2) <- m2
  ans <- emitOp $ f x1 x2
  return ( ans
         , do t1 <- mt1
              t2 <- mt2
              tOut1 <- emitOp $ f x1 t2
              tOut2 <- emitOp $ f t1 x2
              add tOut1 tOut2)

bindLin :: LinA a -> (a -> Embed b) -> LinA b
bindLin (LinA m) f = LinA $ do
  (e, t) <- m
  x <- lift $ f e
  return (x, t >>= (lift . f))

instance Functor LinA where
  fmap = liftA

instance Applicative LinA where
  pure x = LinA $ return (x, return x)
  liftA2 f (LinA m1) (LinA m2) = LinA $ do
    (x1, t1) <- m1
    (x2, t2) <- m2
    return (f x1 x2, liftM2 f t1 t2)

extendWrt :: DerivWrt -> PrimalM a -> PrimalM a
extendWrt (vs, EffectRow effs Nothing) m = local update m
  where update (vs', (EffectRow effs' Nothing)) =
          (vs' <> vs, EffectRow (effs' <> effs) Nothing)
extendWrt _ _ = error "not implemented"

-- -- === transposition ===

type LinVars = Env Atom
type TransposeM a = ReaderT (LinVars, SubstEnv) Embed a

transposeMap :: Scope -> Atom -> Atom
transposeMap scope (Lam (Abs b (_, expr))) = fst $ flip runEmbed scope $ do
  buildLam ("ct" :> getType expr) LinArrow $ \ct -> do
    flip runReaderT mempty $ withLinVar b $ transposeBlock expr ct

transposeBlock :: Block -> Atom -> TransposeM ()
transposeBlock (Block decls result) ct = case decls of
  [] -> transposeExpr result ct
  Let _ b bound : rest -> do
    -- let (eff, _) = getEffType bound
    -- linEff <- isLinEff eff
    let linEff = not $ isPure bound
    lin <- isLin bound
    if lin || linEff
      then do
        ct' <- withLinVar b $ transposeBlock body ct
        transposeExpr bound ct'
      else do
        bound' <- substTranspose bound
        x <- withNameHint (varName b) $ emit bound'
        extendR (asSnd (b@>x)) $ transposeBlock body ct
    where body = Block rest result

transposeExpr :: Expr -> Atom -> TransposeM ()
transposeExpr expr ct = case expr of
  App ~(Var x) i -> case varAnn x of
    TabTy _ _ -> do
      i' <- substTranspose i
      linVars <- asks fst
      ref <- case envLookup linVars x of
               Just ref -> return ref
               -- might be possible to reach here indexing into a literal zero array
               _ -> error "Not implemented"
      ref' <- emitOp $ IndexRef ref i'
      emitCTToRef ref' ct
    _ -> error $ "shouldn't have non-table app left"
  Hof hof -> transposeHof hof ct
  Op op -> transposeOp op ct
  Atom atom -> transposeAtom atom ct

transposeOp :: Op -> Atom -> TransposeM ()
transposeOp op ct = case op of
  Fst x -> do
    let (PairTy _ b) = getType x
    bZero <- zeroAt b
    transposeAtom x $ PairVal ct bZero
  Snd x -> do
    let (PairTy a _) = getType x
    aZero <- zeroAt a
    transposeAtom x $ PairVal aZero ct
  ScalarUnOp FNeg x -> do
    ctNeg <- neg ct
    transposeAtom x ctNeg
  ScalarBinOp FAdd x y -> do
    transposeAtom x ct
    transposeAtom y ct
  ScalarBinOp FSub x y -> do
    ctNeg <- neg ct
    transposeAtom x ct
    transposeAtom y ctNeg
  ScalarBinOp FMul x y -> do
    xLin <- isLin x
    if xLin
      then do
        y' <- substTranspose y
        ct' <- mul ct y'
        transposeAtom x ct'
      else do
        x' <- substTranspose x
        ct' <- mul ct x'
        transposeAtom y ct'
  ScalarBinOp FDiv x y -> do
    y' <- substTranspose y
    ct' <- div' ct y'
    transposeAtom x ct'
  PrimEffect refArg m -> do
    refArg' <- substTranspose refArg
    case m of
      MAsk -> void $ emitOp $ PrimEffect refArg' (MTell ct)
      MTell x -> do
       ct' <- emitOp $ PrimEffect refArg' MAsk
       transposeAtom x ct'
      _ -> error "Not implemented"
  _ -> error $ "not implemented: transposition for: " ++ pprint op

transposeHof :: Hof -> Atom -> TransposeM ()
transposeHof hof ct = case hof of
  For d ~(Lam (Abs b (_, body))) ->
    void $ buildFor (flipDir d) b $ \i -> do
      ct' <- tabGet ct i
      extendR (asSnd (b@>i)) $ transposeBlock body ct'
      return UnitVal
  RunReader r ~(BinaryFunVal _ b _ body) -> do
    (_, ctr) <- (fromPair =<<) $ emitRunWriter "w" (getType r) $ \ref -> do
      extendR (asSnd (b@>ref)) $ transposeBlock body ct
      return UnitVal
    transposeAtom r ctr
  RunWriter ~(BinaryFunVal _ b _ body) -> do
    (ctBody, ctEff) <- fromPair ct
    void $ emitRunReader "r" ctEff $ \ref -> do
      extendR (asSnd (b@>ref)) $ transposeBlock body ctBody
      return UnitVal

transposeCon :: Con -> Atom -> TransposeM ()
transposeCon con _ | isSingletonType (getType (Con con)) = return ()
transposeCon con ct = case con of
  Lit _ -> return ()
  PairCon x y -> do
    getFst ct >>= transposeAtom x
    getSnd ct >>= transposeAtom y
  _ -> error $ "not implemented: transposition for: " ++ pprint con

transposeAtom :: Atom -> Atom -> TransposeM ()
transposeAtom atom ct = case atom of
  Var v -> emitCT v ct
  Con con -> transposeCon con ct
  _ -> error $ "Can't transpose: " ++ pprint atom

freeLinVars :: HasVars a => a -> TransposeM [Var]
freeLinVars x = do
  linVs <- asks fst
  return $ bindingsAsVars $ envIntersect linVs (freeVars x)

isLin :: HasVars a => a -> TransposeM Bool
isLin x = liftM (not . null) $ freeLinVars x

-- TODO: allow nonlinear effects
isLinEff :: EffectRow -> TransposeM Bool
isLinEff = undefined
-- isLinEff ~(Effect row _) = return $ not $ null $ toList row

emitCT :: Var -> Atom -> TransposeM ()
emitCT v ct = do
  linVars <- asks fst
  case envLookup linVars v of
    Just ref -> emitCTToRef ref ct
    _ -> return ()

emitCTToRef :: Atom -> Atom -> TransposeM ()
emitCTToRef ref ct = void $ emitOp $ PrimEffect ref (MTell ct)

substTranspose :: HasVars a => a -> TransposeM a
substTranspose x = do
  env <- asks snd
  scope <- getScope
  return $ subst (env, scope) x

withLinVar :: Var -> TransposeM () -> TransposeM Atom
withLinVar v m = do
  ans <- emitRunWriter "ref" (varAnn v) $ \ref -> do
    extendR (asFst (v@>ref)) (m >> return UnitVal)
  getSnd ans

flipDir :: Direction -> Direction
flipDir Fwd = Rev
flipDir Rev = Fwd
