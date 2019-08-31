{-# LANGUAGE FlexibleContexts #-}

module Imp (impPass, checkImp) where

import Control.Monad.Reader
import Control.Monad.Except (liftEither)
import Data.Foldable

import Syntax
import Env
import Type
import PPrint
import Pass
import Cat
import Record
import Util
import Fresh

data Dest = Buffer Name [Index]
type ImpEnv = (Env IExpr, Env ())
type ImpM a = ReaderT ImpEnv (Either Err) a

impPass :: NTopDecl -> TopPass ImpEnv ImpDecl
impPass decl = case decl of
  NTopDecl decl -> do
    (bs, prog, env) <- liftTop $ toImpDecl decl
    putEnv env
    return $ ImpTopLet bs prog
  NEvalCmd NoOp -> return noOpCmd
  NEvalCmd (Command cmd (ty, ts, expr)) -> do
    ts' <- liftTop $ mapM toImpType ts
    let bs = [Name "%imptmp" i :> t | (i, t) <- zip [0..] ts']
    prog <- liftTop $ toImp (map asDest bs) expr
    case cmd of Passes -> writeOutText $ "\n\nImp\n" ++ pprint prog
                _ -> return ()
    return $ ImpEvalCmd (reconstruct ty) bs (Command cmd prog)
  where
    noOpCmd = ImpEvalCmd (const undefined) [] NoOp
    liftTop :: ImpM a -> TopPass ImpEnv a
    liftTop m = do
      env <- getEnv
      liftEither $ runReaderT m env

toImp :: [Dest] -> NExpr -> ImpM ImpProg
toImp dests expr = case expr of
  NDecls [] body -> toImp dests body
  NDecls (decl:rest) final -> do
    (bs, bound', env) <- toImpDecl decl
    body' <- extendR env $ toImp dests (NDecls rest final)
    return $ wrapAllocs bs $ bound' <> body'
  NScan b@(_:>n) bs xs body -> do
    ~([i:>_], idxEnv ) <- toImpBinders [b]
    xs' <- mapM toImpAtom xs
    n' <- typeToSize n
    let carryEnv = fold $ zipWith (\(v:>_) d -> v @> destAsIExpr d) bs carryDests
    body' <- extendR (idxEnv <> (carryEnv, mempty)) $
               toImp (carryDests <> map (indexDest (IVar i)) mapDests) $ body
    return $ ImpProg $ zipWith copy carryDests xs' ++ [Loop i n' body']
    where
      (carryDests, mapDests) = splitAt (length bs) dests
  NPrimOp b ts xs -> do
    ts' <- mapM toImpType ts
    xs' <- mapM toImpAtom xs
    return $ ImpProg [primOpStatement b dests ts' xs']
  NAtoms xs -> do
    xs' <- mapM toImpAtom xs
    return $ ImpProg $ zipWith copy dests xs'
  NTabCon _ _ rows -> do
    liftM fold $ zipWithM writeRow [0..] rows
    where writeRow i row = toImp (indexedDests i) row
          indexedDests i = map (indexDest (ILit (IntLit i))) dests

toImpDecl :: NDecl -> ImpM ([IBinder], ImpProg, ImpEnv)
toImpDecl decl = case decl of
  NLet bs expr -> do
    (bs', env) <- toImpBinders bs
    expr' <- extendR env $ toImp (map asDest bs') expr
    return (bs', expr', env)
  NUnpack nbs tv expr -> do
    (bs , env ) <- toImpBinders [tv :> NBaseType IntType]
    (bs', env') <- extendR env $ toImpBinders nbs
    let bs'' = bs ++ bs'
        env'' = env <> env'
    expr' <- extendR env'' $ toImp (map asDest bs'') expr
    return (bs'', expr', env'')

toImpBinders :: [NBinder] -> ImpM ([IBinder], ImpEnv)
toImpBinders bs = do
  (vs', scope) <- asks $ renames vs . snd
  ts' <- mapM toImpType ts
  let env = (fold $ zipWith (\v v' -> v @> IVar v') vs vs', scope)
  return (zipWith (:>) vs' ts', env)
  where (vs, ts) = unzip [(v, t) | v:>t <- bs]

toImpAtom :: NAtom -> ImpM IExpr
toImpAtom atom = case atom of
  NLit x -> return $ ILit x
  NVar v -> lookupVar v
  NGet e i -> liftM2 IGet (toImpAtom e) (toImpAtom i)

primOpStatement :: Builtin -> [Dest] -> [IType] -> [IExpr] -> Statement
primOpStatement Range      (dest:_) _ [x] = copy dest x
primOpStatement IndexAsInt [dest]   _ [x] = copy dest x
primOpStatement IntAsIndex [dest]   _ [x] = copy dest x  -- TODO: mod n
primOpStatement b [Buffer name idxs] ts xs = Update name idxs b ts xs

toImpType :: NType -> ImpM IType
toImpType ty = case ty of
  NBaseType b -> return $ IType b []
  NTabType a b -> liftM2 addIdx (typeToSize a) (toImpType b)
  -- TODO: fix this (only works for range)
  NExists [] -> return intTy
  NTypeVar _ -> return intTy
  NIdxSetLit _ -> return intTy
  _ -> error $ "Can't lower type to imp: " ++ pprint ty

lookupVar :: Name -> ImpM IExpr
lookupVar v = do
  x <- asks $ flip envLookup v . fst
  return $ case x of
    Nothing -> IVar v
    Just v' -> v'

addIdx :: Size -> IType -> IType
addIdx n (IType ty shape) = IType ty (n : shape)

typeToSize :: NType -> ImpM IExpr
typeToSize (NTypeVar v) = lookupVar v
typeToSize (NIdxSetLit n) = return $ ILit (IntLit n)

asDest :: BinderP a -> Dest
asDest (v:>_) = Buffer v []

destAsIExpr :: Dest -> IExpr
destAsIExpr (Buffer v idxs) = foldl IGet (IVar v) idxs

indexDest :: Index -> Dest -> Dest
indexDest i (Buffer v destIdxs) = Buffer v (destIdxs `snoc` i)

snoc :: [a] -> a -> [a]
snoc xs x = reverse $ x : reverse xs

wrapAllocs :: [IBinder] -> ImpProg -> ImpProg
wrapAllocs [] prog = prog
wrapAllocs (b:bs) prog = ImpProg [Alloc b (wrapAllocs bs prog)]

-- TODO: copy should probably take a type argument
copy :: Dest -> IExpr -> Statement
copy (Buffer v idxs) x = Update v idxs Copy [] [x]

intTy :: IType
intTy = IType IntType []

reconstruct :: Type -> Env Int -> [Vec] -> Value
reconstruct ty tenv vecs = Value (subty ty) $ restructure vecs (typeLeaves ty)
  where
    typeLeaves :: Type -> RecTree ()
    typeLeaves ty = case ty of BaseType _ -> RecLeaf ()
                               TabType _ valTy -> typeLeaves valTy
                               RecType r -> RecTree $ fmap typeLeaves r
                               _ -> error $ "can't show " ++ pprint ty
    subty :: Type -> Type
    subty ty = case ty of
      BaseType _ -> ty
      TabType (TypeVar v) valTy -> TabType (IdxSetLit (tenv ! v)) (subty valTy)
      TabType n valTy -> TabType n (subty valTy)
      RecType r -> RecType $ fmap subty r
      _ -> error $ "can't show " ++ pprint ty

-- === type checking imp programs ===

type ImpCheckM a = Pass (Env IType) () a

checkImp :: ImpDecl -> TopPass (Env IType) ImpDecl
checkImp decl = decl <$ case decl of
  ImpTopLet binders prog -> do
    check binders prog
    putEnv $ bindFold binders
  ImpEvalCmd _ _ NoOp -> return ()
  ImpEvalCmd _ bs (Command _ prog) -> check bs prog
  where
    check :: [IBinder] -> ImpProg -> TopPass (Env IType) ()
    check bs prog = do
      env <- getEnv
      liftEither $ addContext (pprint prog) $
          evalPass (env <> bindFold bs) () mempty (checkProg prog)

checkProg :: ImpProg -> ImpCheckM ()
checkProg (ImpProg statements) = mapM_ checkStatement statements

checkStatement :: Statement -> ImpCheckM ()
checkStatement statement = case statement of
  Alloc b body -> do
    env <- ask
    if binderVar b `isin` env then throw CompilerErr $ "shadows:" ++ pprint b
                              else return ()
    extendR (bind b) (checkProg body)
  Update v idxs Copy [] [expr] -> do
    mapM_ checkInt idxs
    IType b  shape  <- asks $ (! v)
    IType b' shape' <- impExprType expr
    assertEq b b' "Base type mismatch in copy"
    assertEq (drop (length idxs) shape) shape' "Dimension mismatch"
  Update _ _ (FFICall _ _) _ _ -> return () -- TODO: check polymorphic builtins
  Update v idxs builtin _ args -> do -- scalar builtins only for now
    argTys <- mapM impExprType args
    let BuiltinType _ inTys retTy = builtinType builtin
    zipWithM_ checkScalarTy inTys argTys
    IType b' shape  <- asks $ (! v)
    case drop (length idxs) shape of
      [] -> assertEq retTy (BaseType b') "Base type mismatch in builtin application"
      _  -> throw CompilerErr "Writing to non-scalar buffer"
  Loop i size block -> extendR (i @> intTy) $ do
                          checkInt size
                          checkProg block

impExprType :: IExpr -> ImpCheckM IType
impExprType expr = case expr of
  ILit val -> return $ IType (litType val) []
  IVar v   -> asks $ (! v)
  IGet e i -> do ~(IType b (_:shape)) <- impExprType e
                 checkInt i
                 return $ IType b shape

checkScalarTy :: Type -> IType -> ImpCheckM ()
checkScalarTy (BaseType b) (IType b' []) | b == b'= return ()
checkScalarTy ty ity = throw CompilerErr $ "Wrong types. Expected:" ++ pprint ty
                                                         ++ " Got " ++ pprint ity

checkInt :: IExpr -> ImpCheckM ()
checkInt (IVar v) = do ty <- asks $ (! v)
                       assertEq ty intTy "Not a valid int"
checkInt (ILit (IntLit _)) = return ()
checkInt expr = throw CompilerErr $ "Not an int: " ++ pprint expr
