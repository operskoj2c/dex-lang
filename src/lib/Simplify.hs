-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplify (simplifyModule) where

import Data.Bitraversable
import Control.Monad
import Control.Monad.Reader

import Autodiff
import Env
import Syntax
import Cat
import Embed
import Record
import Type
import PPrint
import Util (uncurry3)

type SimpEnv = SubstEnv
data SimpOpts = SimpOpts { preserveDerivRules :: Bool }
type SimplifyM a = ReaderT SimpEnv (ReaderT ((SubstEnv, RuleEnv), SimpOpts) Embed) a

simplifyModule :: SubstEnv -> RuleEnv -> Module -> (Module, SubstEnv)
simplifyModule substEnv rulesEnv m = (mOut', subst (envOut', mempty) envOut)
  where (mOut , envOut ) = simplifyModuleOpts (SimpOpts True ) (substEnv, rulesEnv) m
        (mOut', envOut') = simplifyModuleOpts (SimpOpts False) (substEnv, rulesEnv) mOut

simplifyModuleOpts :: SimpOpts -> (SubstEnv, RuleEnv)
                   -> Module -> (Module, SubstEnv)
simplifyModuleOpts opts env (Module bid _ exports expr) =
  (Module bid imports' exports' expr', outEnv)
  where
    (exports', expr', results) = runSimplifyM opts env $ simplifyTop expr
    imports' = map (uncurry (:>)) $ envPairs $ freeVars expr'
    outEnv = newEnv exports results

runSimplifyM :: SimpOpts -> (SubstEnv, RuleEnv) -> SimplifyM a -> a
runSimplifyM opts env m =
  fst $ flip runEmbed mempty $ flip runReaderT (env, opts) $
    flip runReaderT mempty m

simplifyTop :: Block -> SimplifyM ([Var], Block, [Atom])
simplifyTop block = do
  ~(ans@(TupVal results), (scope, decls)) <- embedScoped $ simplifyBlock block
  let vs = map (uncurry (:>)) $ envPairs $ scope `envIntersect` freeVars ans
  let expr' = wrapDecls decls $ TupVal $ map Var vs
  return (vs, expr', results)  -- no need to choose fresh names

simplifyBlock :: Block -> SimplifyM Atom
simplifyBlock (Block (decl:decls) result) = do
   env <- simplifyDecl decl
   extendR env $ simplifyBlock body
   where body = Block decls result
simplifyBlock (Block [] result) = simplifyExpr result

simplifyAtom :: Atom -> SimplifyM Atom
simplifyAtom atom = case atom of
  Var v -> do
    -- TODO: simplify this by requiring different namespaces for top/local vars
    ((topEnv, rulesEnv), opts) <- lift ask
    localEnv <- ask
    case envLookup localEnv v of
      Just x -> deShadow x <$> getScope
      Nothing -> case envLookup topEnv v of
        Just x
          | preserveDerivRules opts && v `isin` rulesEnv -> substEmbed atom
          | otherwise -> dropSub $ simplifyAtom x
        _             -> substEmbed atom
  -- We don't simplify body of lam because we'll beta-reduce it soon.
  Lam _ _ -> substEmbed atom
  Con (AnyValue (TabTy a b)) -> Con . AFor a <$> mkAny b
  Con (AnyValue (RecTy r))   -> RecVal <$> mapM mkAny r
  Con (AnyValue (SumTy l r)) -> do
    Con <$> (SumCon <$> mkAny (TC $ BaseType BoolType) <*> mkAny l <*> mkAny r)
  Con con -> Con <$> mapM simplifyAtom con
  TC tc -> TC <$> mapM substEmbed tc
  where mkAny t = Con . AnyValue <$> substEmbed t >>= simplifyAtom

-- Unlike `substEmbed`, this simplifies under the binder too.
simplifyLam :: Atom -> SimplifyM (Atom, Maybe (Atom -> SimplifyM Atom))
simplifyLam (Lam ah (Abs b (eff, body))) = do
  b' <- mapM substEmbed b
  if isData (getType body)
    then do
      lam <- buildLam ah b' $ \x -> extendR (b@>x) $ simplifyEffBlock eff body
      return (lam, Nothing)
    else do
      (lam, recon) <- buildLamAux ah b' $ \x -> extendR (b@>x) $ do
        ((eff', body'), (scope, decls)) <- embedScoped $ simplifyEffBlock eff body
        mapM_ emitDecl decls
        let (result, recon) = separateDataComponent scope body'
        return ((eff', result), recon)
      return $ (lam, Just recon)

simplifyEffBlock :: Effects -> Block -> SimplifyM (Effects, Atom)
simplifyEffBlock eff block = (,) <$> substEmbed eff <*> simplifyBlock block

separateDataComponent :: MonadEmbed m => Scope -> Atom -> (Atom, Atom -> m Atom)
separateDataComponent localVars atom = (TupVal $ map Var vs, recon)
  where
    vs = map (uncurry (:>)) $ envPairs $ localVars `envIntersect` freeVars atom
    recon :: MonadEmbed m => Atom -> m Atom
    recon xs = do
      ~(Tup xs') <- unpackRec xs
      scope <- getScope
      return $ subst (newEnv vs xs', scope) atom

reconstructAtom :: MonadEmbed m
                => Maybe (Atom -> m Atom) -> Atom -> m Atom
reconstructAtom recon x = case recon of
  Nothing -> return x
  Just f  -> f x

simplifyExpr :: Expr -> SimplifyM Atom
simplifyExpr expr = case expr of
  App h f x -> do
    x' <- simplifyAtom x
    f' <- simplifyAtom f
    case f' of
      Lam _ (Abs b (_, body)) ->
        dropSub $ extendR (b@>x') $ simplifyBlock body
      _ -> emit $ App h f' x'
  Op  op  -> mapM simplifyAtom op >>= simplifyOp
  Hof hof -> simplifyHof hof
  Atom x  -> simplifyAtom x

-- TODO: come up with a coherent strategy for ordering these various reductions
simplifyOp :: Op -> SimplifyM Atom
simplifyOp op = case op of
  Cmp Equal t a b -> resolveEq t a b
  Cmp cmpOp t a b -> resolveOrd cmpOp t a b
  RecGet (RecVal r) i -> return $ recGet r i
  SumGet (SumVal _ l r) getLeft -> return $ if getLeft then l else r
  SumTag (SumVal s _ _) -> return $ s
  Select p x y -> selectAt (getType x) p x y
  _ -> emitOp op

simplifyHof :: Hof -> SimplifyM Atom
simplifyHof hof = case hof of
  For d lam -> do
    ~(lam', Nothing) <- simplifyLam lam
    emit $ Hof $ For d lam'
--   Linearize (lam, _) -> do
--     rulesEnv <- lift $ asks (snd . fst)
--     scope <- getScope
--     -- TODO: simplify the result to remove functions introduced by linearization
--     return $ linearize rulesEnv scope lam
--   -- Transpose (lam, _) -> do
--   --   scope <- getScope
--   --   return $ transposeMap scope lam
--   RunReader r (lam, recon) -> do
--     ans <- emit $ Hof $ RunReader r lam
--     reconstructAtom recon ans
--   RunWriter (lam, recon) -> do
--     (ans, w) <- fromPair =<< emit (Hof $ RunWriter lam)
--     ans' <- reconstructAtom recon ans
--     return $ PairVal ans' w
  RunState s lam -> do
    s' <- simplifyAtom s
    let ~(BinaryFunVal regionBinder refBinder eff body) = lam
    regionBinder' <- mapM substEmbed regionBinder
    lam' <- buildLam PlainArrow regionBinder' $ \region ->
      extendR (regionBinder'@>region) $ liftM (Pure,) $ do
        refBinder' <- mapM substEmbed refBinder
        buildLam PlainArrow refBinder' $ \ref -> do
          extendR (refBinder'@>ref) $ simplifyEffBlock eff body
    emit $ Hof $ RunState s' lam'

-- simplifyLam :: Atom -> SimplifyM (Atom, Maybe (Atom -> SimplifyM Atom))
-- simplifyLam (Lam ah (Abs b (eff, body))) = do
--   b' <- mapM substEmbed b
--   if isData (getType body)
--     then do
--       lam <- buildLam ah b' $ \x -> extendR (b@>x) $ simplifyEffBlock eff body
--       return (lam, Nothing)

    -- (ans, s') <- fromPair =<< emit (Hof $ RunState s lam)
    -- ans' <- reconstructAtom recon ans
    -- return $ PairVal ans' s'
--   -- SumCase c (lBody, _) (rBody, _) -> do
--   --   l <- projApp lBody True
--   --   r <- projApp rBody False
--   --   isLeft <- simplRec $ Op $ SumTag c
--   --   emitOp $ Select isLeft l r
--   --   where
--   --     simplRec :: Expr -> SimplifyM Atom
--   --     simplRec = dropSub . simplifyExpr
--   --     projApp body isLeft = do
--   --       cComp <- simplRec $ Op $ SumGet c isLeft
--   --       simplRec $ App PlainArrow (Lam PlainArrow body) cComp

resolveEq :: Type -> Atom -> Atom -> SimplifyM Atom
resolveEq t x y = case t of
  IntTy     -> emitOp $ ScalarBinOp (ICmp Equal) x y
  RealTy    -> emitOp $ ScalarBinOp (FCmp Equal) x y
  RecTy ts  -> do
    xs <- unpackRec x
    ys <- unpackRec y
    equals <- mapM (uncurry3 resolveEq) $ recZipWith3 (,,) ts xs ys
    foldM andE (BoolVal True) equals
  -- instance Eq a => Eq n=>a
  -- TabTy ixty elty -> do
  --   writerLam <- buildAbsBlock ("ref":> RefTy RealTy) $ \ref -> do
  --     forLam <- buildAbsBlock ("i":>ixty) $ \i -> do
  --       (x', y') <- (,) <$> nTabGet x i <*> nTabGet y i
  --       eqReal <- boolToReal =<< resolveEq elty x' y'
  --       emitOp $ PrimEffect ref $ MTell eqReal
  --     emit $ For Fwd forLam
  --   idxSetSize <- intToReal =<< emitOp (IdxSetSize ixty)
  --   total <- snd <$> (fromPair =<< emit (Hof $ RunWriter writerLam))
  --   emitOp $ Cmp Equal RealTy total idxSetSize
  -- instance (Eq a, Eq b) => Eq (Either a b)
  SumTy lty rty -> do
    xt <- emitOp $ SumTag x
    yt <- emitOp $ SumTag y
    tagsEq <- resolveEq BoolTy xt yt
    lEq <- compareSide True
    rEq <- compareSide False
    sideEq <- select xt lEq rEq
    andE tagsEq sideEq
    where
      compareSide isLeft = do
        xe <- emitOp $ SumGet x isLeft
        ye <- emitOp $ SumGet y isLeft
        resolveEq (if isLeft then lty else rty) xe ye
  -- instance Idx a => Eq a
  BoolTy                -> idxEq
  TC (IntRange _ _)     -> idxEq
  TC (IndexRange _ _ _) -> idxEq
  _ -> error $ pprint t ++ " doesn't implement Eq"
  where
    idxEq = do
      xi <- emitOp $ IndexAsInt x
      yi <- emitOp $ IndexAsInt y
      emitOp $ ScalarBinOp (ICmp Equal) xi yi

resolveOrd :: CmpOp -> Type -> Atom -> Atom -> SimplifyM Atom
resolveOrd op t x y = case t of
  IntTy  -> emitOp $ ScalarBinOp (ICmp op) x y
  RealTy -> emitOp $ ScalarBinOp (FCmp op) x y
  TC con -> case con of
    IntRange _ _     -> idxOrd
    IndexRange _ _ _ -> idxOrd
    _ -> error $ pprint t ++ " doesn't implement Ord"
  _ -> error $ pprint t ++ " doesn't implement Ord"
  where
    idxOrd = do
      xi <- emitOp $ IndexAsInt x
      yi <- emitOp $ IndexAsInt y
      emitOp $ ScalarBinOp (ICmp op) xi yi

simplifyDecl :: Decl -> SimplifyM SimpEnv
simplifyDecl decl = case decl of
  Let b bound -> do
    x <- simplifyExpr bound
    return $ b @> x

dropSub :: SimplifyM a -> SimplifyM a
dropSub m = local mempty m
