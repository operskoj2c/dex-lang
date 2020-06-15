-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UndecidableInstances #-}

module Embed (emit, emitOp, buildDepEffLam, buildLamAux, buildAbs,
              getAllowedEffects, withEffects, modifyAllowedEffects,
              buildLam, EmbedT, Embed, MonadEmbed, buildScoped, wrapDecls, runEmbedT,
              runEmbed, zeroAt, addAt, sumAt, getScope, reduceBlock, withBinder,
              app, add, mul, sub, neg, div', andE, reduceScoped, declAsScope,
              select, selectAt, substEmbed, fromPair, getFst, getSnd,
              emitBlock, unzipTab, buildFor, isSingletonType, emitDecl, withNameHint,
              singletonTypeVal, mapScalars, scopedDecls, embedScoped, extendScope,
              embedExtend, boolToInt, intToReal, boolToReal, reduceAtom,
              unpackConsList, emitRunWriter, tabGet) where

import Control.Monad
import Control.Monad.Fail
import Control.Monad.Except hiding (Except)
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.Identity
import Data.Foldable (toList)
import Data.Maybe

import Env
import Syntax
import Cat
import Type
import PPrint

newtype EmbedT m a = EmbedT (ReaderT EmbedEnvR (CatT EmbedEnvC m) a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadFail)

type Embed = EmbedT Identity
type EmbedEnv = (EmbedEnvR, EmbedEnvC)
type EmbedEnvC = (Scope, [Decl])
type EmbedEnvR = (Name, EffectRow)

runEmbedT :: Monad m => EmbedT m a -> Scope -> m (a, [Decl])
runEmbedT (EmbedT m) scope = do
  (ans, (_, decls)) <- runCatT (runReaderT m (NoName, Pure)) (scope, [])
  return (ans, decls)

runEmbed :: Embed a -> Scope -> (a, [Decl])
runEmbed m scope = runIdentity $ runEmbedT m scope

-- TODO: use suggestive names based on types (e.g. "f" for function)
emit :: MonadEmbed m => Expr -> m Atom
emit expr = do
  v <- getNameHint
  let ty = getType expr
  case singletonTypeVal ty of
    Nothing -> do
      expr' <- deShadow expr <$> getScope
      v' <- freshVar (v:>ty)
      emitDecl $ Let v' expr'
      return $ Var v'
    Just x
      | isPure expr -> return x
      | otherwise -> do
          expr' <- deShadow expr <$> getScope
          emitDecl $ Let (NoName:>ty) expr'
          return x

emitOp :: MonadEmbed m => Op -> m Atom
emitOp op = emit $ Op op

-- Assumes the decl binders are already fresh wrt current scope
emitBlock :: MonadEmbed m => Block -> m Atom
emitBlock (Block decls result) = mapM_ emitDecl decls >> emit result

freshVar :: MonadEmbed m => VarP ann -> m (VarP ann)
freshVar v = do
  scope <- getScope
  let v' = rename v scope
  return v'

-- Runs second argument on a fresh binder variable and returns its result,
-- the fresh variable name and the EmbedEnv accumulated during its execution.
-- The first argument specifies the type of the binder variable, and is used
-- as a hint for its name.
withBinder :: (MonadEmbed m) => Var -> (Atom -> m a) -> m (a, Var, [Decl])
withBinder b f = do
  ((ans, b'), decls) <- scopedDecls $ do
      b' <- freshVar b
      embedExtend $ asFst (b' @> Nothing)
      ans <- f $ Var b'
      return (ans, b')
  return (ans, b', decls)

buildAbs :: (MonadError Err m, HasVars a, MonadEmbed m)
         => Var -> (Atom -> m a) -> m (Abs a)
buildAbs b f = do
  (ans, b', decls) <- withBinder b f
  unless (null decls) $ throw CompilerErr $ "Unexpected decls: " ++ pprint decls
  return $ makeAbs b' ans

buildLam :: MonadEmbed m => Var -> Arrow -> (Atom -> m Atom) -> m Atom
buildLam b arr body = buildDepEffLam b (const (return arr)) body

buildDepEffLam :: MonadEmbed m
               => Var -> (Atom -> m Arrow) -> (Atom -> m Atom) -> m Atom
buildDepEffLam b fArr fBody = liftM fst $ buildLamAux b fArr $ \x -> (,()) <$> fBody x

buildLamAux :: MonadEmbed m
            => Var -> (Atom -> m Arrow) -> (Atom -> m (Atom, a)) -> m (Atom, a)
buildLamAux b fArr fBody = do
  ((arr, (ans, aux)), b', decls) <- withBinder b $ \x -> do
    arr <- fArr x
    (ansAux) <- withEffects (arrowEff arr) $ fBody x
    return (arr, ansAux)
  return (Lam (Abs b' (arr, wrapDecls decls ans)), aux)

buildScoped :: (MonadEmbed m) => m Atom -> m Block
buildScoped m = do
  (ans, decls) <- scopedDecls m
  return $ wrapDecls decls ans

wrapDecls :: [Decl] -> Atom -> Block
wrapDecls decls atom = case reverse decls of
  -- decluttering optimization
  Let v expr:rest | atom == Var v -> Block (reverse rest) expr
  _ -> Block decls (Atom atom)

-- TODO: consider broadcasted literals as atoms, so we don't need the monad here
zeroAt :: MonadEmbed m => Type -> m Atom
zeroAt ty = mapScalars (\_ _ -> return $ Con $ Lit (RealLit 0.0)) ty []

addAt :: MonadEmbed m => Type -> Atom -> Atom -> m Atom
addAt ty xs ys = mapScalars (\_ [x, y] -> add x y) ty [xs, ys]

selectAt :: MonadEmbed m => Type -> Atom -> Atom -> Atom -> m Atom
selectAt ty p xs ys = mapScalars (\_ [x, y] -> select p x y) ty [xs, ys]

sumAt :: MonadEmbed m => Type -> [Atom] -> m Atom
sumAt ty [] = zeroAt ty
sumAt _ [x] = return x
sumAt ty (x:xs) = do
  xsSum <- sumAt ty xs
  addAt ty xsSum x

neg :: MonadEmbed m => Atom -> m Atom
neg x = emitOp $ ScalarUnOp FNeg x

add :: MonadEmbed m => Atom -> Atom -> m Atom
add (RealVal 0) y = return y
add x y           = emitOp $ ScalarBinOp FAdd x y

mul :: MonadEmbed m => Atom -> Atom -> m Atom
mul x y = emitOp $ ScalarBinOp FMul x y

sub :: MonadEmbed m => Atom -> Atom -> m Atom
sub x y = emitOp $ ScalarBinOp FSub x y

andE :: MonadEmbed m => Atom -> Atom -> m Atom
andE (BoolVal True) y = return y
andE x y              = emit $ Op $ ScalarBinOp And x y

select :: MonadEmbed m => Atom -> Atom -> Atom -> m Atom
select p x y = emitOp $ Select p x y

div' :: MonadEmbed m => Atom -> Atom -> m Atom
div' x y = emitOp $ ScalarBinOp FDiv x y

getFst :: MonadEmbed m => Atom -> m Atom
getFst (PairVal x _) = return x
getFst p = emitOp $ Fst p

getSnd :: MonadEmbed m => Atom -> m Atom
getSnd (PairVal _ y) = return y
getSnd p = emitOp $ Snd p

app :: MonadEmbed m => Atom -> Atom -> m Atom
app x i = emit $ App x i

fromPair :: MonadEmbed m => Atom -> m (Atom, Atom)
fromPair (PairVal x y) = return (x, y)
fromPair pair          = error $ "Not a pair: " ++ pprint pair

unpackConsList :: MonadEmbed m => Atom -> m [Atom]
unpackConsList = undefined

emitRunWriter :: MonadEmbed m => Name -> Type -> (Atom -> m Atom) -> m Atom
emitRunWriter v ty body = do
  eff <- getAllowedEffects
  lam <- buildLam ("r":>TyKind) PureArrow $ \r@(Var (rName:>_)) -> do
    let arr = PlainArrow $ extendEffect (Writer, rName) eff
    buildLam (v:> RefTy r ty) arr body
  emit $ Hof $ RunWriter lam

buildFor :: MonadEmbed m => Direction -> Var -> (Atom -> m Atom) -> m Atom
buildFor d i body = do
  -- TODO: track effects in the embedding env so we can add them here
  eff <- getAllowedEffects
  lam <- buildLam i (PlainArrow eff) body
  emit $ Hof $ For d lam

tabGet :: MonadEmbed m => Atom -> Atom -> m Atom
tabGet x i = emit $ App x i

unzipTab :: MonadEmbed m => Atom -> m (Atom, Atom)
unzipTab tab = do
  fsts <- buildFor Fwd ("i":>n) $ \i ->
            liftM fst $ app tab i >>= fromPair
  snds <- buildFor Fwd ("i":>n) $ \i ->
            liftM snd $ app tab i >>= fromPair
  return (fsts, snds)
  where TabTy n _ = getType tab

mapScalars :: MonadEmbed m => (Type -> [Atom] -> m Atom) -> Type -> [Atom] -> m Atom
mapScalars f ty xs = case ty of
  TabTy n a -> do
    buildFor Fwd ("i":>n) $ \i -> do
      xs' <- mapM (flip app i) xs
      mapScalars f a xs'
  BaseTy _           -> f ty xs
  TC con -> case con of
    -- NOTE: Sum types not implemented, because they don't have a total zipping function!
    IntRange _ _     -> f ty xs
    IndexRange _ _ _ -> f ty xs
    _ -> error $ "Not implemented " ++ pprint ty
  _ -> error $ "Not implemented " ++ pprint ty

substEmbed :: (MonadEmbed m, MonadReader SubstEnv m, HasVars a)
           => a -> m a
substEmbed x = do
  env <- ask
  scope <- getScope
  return $ subst (env, scope) x

isSingletonType :: Type -> Bool
isSingletonType ty = case singletonTypeVal ty of
  Nothing -> False
  Just _  -> True

singletonTypeVal :: Type -> Maybe Atom
singletonTypeVal (TabTy n a) = liftM (Con . AFor n) $ singletonTypeVal a
singletonTypeVal (TC con) = case con of
  -- XXX: This returns Nothing if it's a record that is not an empty tuple (or contains
  --      anything else than only empty tuples inside)!
  PairType a b -> liftM2 PairVal (singletonTypeVal a) (singletonTypeVal b)
  UnitType     -> return UnitVal
  _            -> Nothing
singletonTypeVal _ = Nothing

boolToInt :: MonadEmbed m => Atom -> m Atom
boolToInt b = emitOp $ ScalarUnOp BoolToInt b

intToReal :: MonadEmbed m => Atom -> m Atom
intToReal i = emitOp $ ScalarUnOp IntToReal i

boolToReal :: MonadEmbed m => Atom -> m Atom
boolToReal = boolToInt >=> intToReal

instance MonadTrans EmbedT where
  lift m = EmbedT $ lift $ lift m

class Monad m => MonadEmbed m where
  embedLook   :: m EmbedEnvC
  embedExtend :: EmbedEnvC -> m ()
  embedScoped :: m a -> m (a, EmbedEnvC)
  embedAsk    :: m EmbedEnvR
  embedLocal  :: (EmbedEnvR -> EmbedEnvR) -> m a -> m a

instance Monad m => MonadEmbed (EmbedT m) where
  embedLook = EmbedT look
  embedExtend env = EmbedT $ extend env
  embedScoped (EmbedT m) = EmbedT $ scoped m
  embedAsk = EmbedT ask
  embedLocal f (EmbedT m) = EmbedT $ local f m

instance MonadEmbed m => MonadEmbed (ReaderT r m) where
  embedLook = lift embedLook
  embedExtend x = lift $ embedExtend x
  embedScoped m = ReaderT $ \r -> embedScoped $ runReaderT m r
  embedAsk = lift embedAsk
  embedLocal v m = ReaderT $ \r -> embedLocal v $ runReaderT m r

instance (Monoid env, MonadEmbed m) => MonadEmbed (CatT env m) where
  embedLook = undefined
  embedExtend _ = error "not implemented"
  embedScoped _ = error "not implemented"
  embedAsk = lift embedAsk
  embedLocal = undefined

instance (Monoid w, MonadEmbed m) => MonadEmbed (WriterT w m) where
  embedLook = lift embedLook
  embedExtend x = lift $ embedExtend x
  embedScoped m = do
    ((x, w), env) <- lift $ embedScoped $ runWriterT m
    tell w
    return (x, env)
  embedAsk = lift embedAsk
  embedLocal v m = WriterT $ embedLocal v $ runWriterT m

instance (Monoid env, MonadCat env m) => MonadCat env (EmbedT m) where
  look = lift look
  extend x = lift $ extend x
  scoped (EmbedT m) = EmbedT $ do
    name <- ask
    env <- look
    ((ans, env'), scopeEnv) <- lift $ lift $ scoped $ runCatT (runReaderT m name) env
    extend env'
    return (ans, scopeEnv)

instance MonadError e m => MonadError e (EmbedT m) where
  throwError = lift . throwError
  catchError m catch = do
    envC <- embedLook
    envR <- embedAsk
    (ans, envC') <- lift $ runEmbedT' m (envR, envC)
                     `catchError` (\e -> runEmbedT' (catch e) (envR, envC))
    embedExtend envC'
    return ans

getNameHint :: MonadEmbed m => m Name
getNameHint = do
  v <- fst <$> embedAsk
  return $ case v of
    NoName -> "tmp"
    _      -> v

withNameHint :: MonadEmbed m => Name -> m a -> m a
withNameHint name m = embedLocal (\(_, eff) -> (name, eff)) m

runEmbedT' :: Monad m => EmbedT m a -> EmbedEnv -> m (a, EmbedEnvC)
runEmbedT' (EmbedT m) (envR, envC) = runCatT (runReaderT m envR) envC

getScope :: MonadEmbed m => m Scope
getScope = fst <$> embedLook

extendScope :: MonadEmbed m => Scope -> m ()
extendScope scope = embedExtend $ asFst scope

getAllowedEffects :: MonadEmbed m => m EffectRow
getAllowedEffects = snd <$> embedAsk

withEffects :: MonadEmbed m => EffectRow -> m a -> m a
withEffects effs m = modifyAllowedEffects (const effs) m

modifyAllowedEffects :: MonadEmbed m => (EffectRow -> EffectRow) -> m a -> m a
modifyAllowedEffects f m = embedLocal (\(name, eff) -> (name, f eff)) m

emitDecl :: MonadEmbed m => Decl -> m ()
emitDecl decl@(Let v expr) = embedExtend (v @> Just expr, [decl])

scopedDecls :: MonadEmbed m => m a -> m (a, [Decl])
scopedDecls m = do
  (ans, (_, decls)) <- embedScoped m
  return (ans, decls)

-- TODO: consider checking for effects here
declAsScope :: Decl -> Scope
declAsScope (Let v expr) = v @> Just expr

-- === partial evaluation using definitions in scope ===

reduceScoped :: MonadEmbed m => m Atom -> m (Maybe Atom)
reduceScoped m = do
  block <- buildScoped m
  scope <- getScope
  return $ reduceBlock scope block

reduceBlock :: Scope -> Block -> Maybe Atom
reduceBlock scope (Block decls result) = do
  let localScope = foldMap declAsScope decls
  ans <- reduceExpr (scope <> localScope) result
  [] <- return $ toList $ localScope `envIntersect` freeVars ans
  return ans

reduceAtom :: Scope -> Atom -> Atom
reduceAtom scope x = case x of
  Var v -> case scope ! v of
    Nothing -> x
    Just expr -> fromMaybe x $ reduceExpr scope expr
  _ -> x

reduceExpr :: Scope -> Expr -> Maybe Atom
reduceExpr scope expr = case expr of
  Atom  val  -> return $ reduceAtom scope val
  App f x -> do
    let f' = reduceAtom scope f
    let x' = reduceAtom scope x
    -- TODO: Worry about variable capture. Should really carry a substitution.
    Lam (Abs b (PureArrow, block)) <- return f'
    reduceBlock scope $ scopelessSubst (b@>x') block
  _ -> Nothing
