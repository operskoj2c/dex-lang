module DeShadow (deShadowPass) where

import Control.Monad.Reader
import Control.Monad.Except hiding (Except)

import Env
import Record
import Syntax
import Pass
import Fresh
import PPrint
import Util (repeated)

type DeShadowM a = ReaderT DeShadowEnv (FreshRT (Either Err)) a
type DeShadowEnv = FullEnv Var Var
type Ann = Maybe Type

deShadowPass :: UDecl -> TopPass FreshScope (TopDeclP Ann)
deShadowPass decl = case decl of
  UTopLet IgnoreBind _ -> error "todo"
  UTopLet (UBind b) expr -> do
    mapM checkTopShadow (binderVars b)
    putEnv (foldMap newScope (binderVars b))
    liftM (TopLet b) $ deShadowTop expr
  UTopUnpack b tv expr -> do
    mapM checkTopShadow (uBinderVars b)
    checkTopShadow tv
    let b' = case b of UBind b' -> b'
                       IgnoreBind -> rawName ("__" ++ nameTag tv) %> Nothing
    putEnv (foldMap newScope (binderVars b'))
    liftM (TopUnpack b' tv) $ deShadowTop expr
  UEvalCmd NoOp -> return (EvalCmd NoOp)
  UEvalCmd (Command cmd expr) -> do
    expr' <- deShadowTop expr
    case cmd of Passes -> writeOut $ "\n\nDeshadowed\n" ++ show expr'
                _ -> return ()
    return $ EvalCmd (Command cmd expr')
  where
    deShadowTop :: UExpr -> TopPass FreshScope (ExprP Ann)
    deShadowTop expr = do
      scope <- getEnv
      liftEither $ runFreshRT (runReaderT (deShadowExpr expr) mempty) scope

checkTopShadow :: Var -> TopPass FreshScope ()
checkTopShadow (Name "_" _) = return ()
checkTopShadow v = do
  scope <- getEnv
  if isFresh v scope then return ()
                     else throw RepeatedVarErr (pprint v)

uBinderVars :: UBinder -> [Var]
uBinderVars (UBind (Bind v _)) = [v]
uBinderVars IgnoreBind = []

deShadowExpr :: UExpr -> DeShadowM (ExprP Ann)
deShadowExpr expr = case expr of
  ULit x -> return (Lit x)
  UVar v -> liftM Var (getLVar v)
  UBuiltin b -> return (Builtin b)
  ULet p bound body -> do
    bound' <- recur bound
    (body', b) <- deShadowPat p (recur body)
    return $ Decls [Let b bound'] body'
  ULam p body -> do
    (body', b) <- deShadowPat p (recur body)
    return $ Lam b body'
  UApp fexpr arg -> liftM2 App (recur fexpr) (recur arg)
  UFor b body -> do
    (body', b') <- deShadowPat (RecLeaf b) (recur body)
    return $ For b' body'
  UGet e v -> liftM2 Get (recur e) (getLVar v)
  UUnpack b tv bound body -> do
    bound' <- recur bound
    freshName tv $ \tv' ->
      extendWith (asTEnv (tv @> tv')) $ do
        (body', b') <- deShadowPat (RecLeaf b) (recur body)
        return $ Decls [Unpack b' tv' bound'] body'
  URecCon r -> liftM RecCon $ traverse recur r
  UAnnot body ty -> liftM2 Annot (recur body) (deShadowType ty)
  where recur = deShadowExpr
        getLVar :: Var -> DeShadowM Var
        getLVar v = asks $ lookupSubst v . lEnv
        deShadowAnnot b = fmap (fmap deShadowType) b

deShadowPat :: RecTree UBinder -> DeShadowM (ExprP Ann)
            -> DeShadowM (ExprP Ann, BinderP Ann)
deShadowPat pat cont = do
  checkRepeats pat
  pat' <- traverse deShadowBinderAnn pat
  case pat' of
    RecLeaf (UBind b) ->
      freshenBinder b $ \subst b' ->
        extendWith (asLEnv subst) $ do
          expr <- cont
          return (expr, b')
    p -> freshName (rawName "pat") $ \v -> do
           expr <- foldr (patGetter v) cont (recTreeNamed p)
           return (expr, v %> Nothing)

patGetter :: Var -> ([RecField], UBinder)
                    -> DeShadowM (ExprP Ann) -> DeShadowM (ExprP Ann)
patGetter _ (_, IgnoreBind) cont = cont
patGetter patName (fields, (UBind b)) cont =
  freshenBinder b $ \subst b' ->
    extendWith (asLEnv subst) $ do
      expr' <- cont
      return $ Decls [Let b' getExpr] expr'
  where
    getExpr = foldr (flip RecGet) (Var patName) fields

deShadowType :: Type -> DeShadowM Type
deShadowType ty = do
  subst <- asks $ tEnv
  let sub v = Just (TypeVar (lookupSubst v subst))
  return $ maybeSub sub ty

deShadowBinderAnn :: UBinder -> DeShadowM UBinder
deShadowBinderAnn IgnoreBind = return IgnoreBind
deShadowBinderAnn (UBind b) = liftM UBind $ traverse (traverse deShadowType) b

checkRepeats :: Foldable f => f UBinder -> DeShadowM ()
checkRepeats bs = case repeated (foldMap uBinderVars bs) of
                    [] -> return ()
                    xs -> throw RepeatedVarErr (pprint xs)
