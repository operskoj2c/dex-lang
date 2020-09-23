-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DerivingVia #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Imp (toImpModule, getIType, impBlockType, impFunType, getMainFun,
            toScalarType, fromScalarType, impMainFunName) where

import Prelude hiding (pi, abs)
import Control.Monad.Reader
import Control.Monad.Except hiding (Except)
import Control.Monad.State
import Control.Monad.Writer hiding (Alt)
import Data.Text.Prettyprint.Doc
import Data.Functor
import Data.Foldable (toList)
import Data.Coerce
import Data.Int
import Data.Maybe (fromJust)
import GHC.Stack
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as M

import Embed
import Syntax
import Env
import Type
import PPrint
import Cat
import qualified Algebra as A
import Util

-- Note [Valid Imp atoms]
--
-- The Imp translation functions as an interpreter for the core IR, which has a side effect
-- of emitting a low-level Imp program that would do the actual math. As an interpreter, each
-- expression has to produce a valid result Atom, that can be used as an input to all later
-- equations. However, because the Imp IR only supports a very limited selection of types
-- (really only base types and pointers to scalar tables), it is safe to assume that only
-- a subset of atoms can be returned by the impSubst. In particular, the atoms might contain
-- only:
--   * Variables of base type or array type
--   * Table lambdas
--   * Constructors for: pairs, sum types, AnyValue, Unit and Coerce
--
-- TODO: Use an ImpAtom type alias to better document the code

data ParallelismLevel = TopLevel | ThreadLevel  deriving (Show, Eq)
data ImpCtx = ImpCtx { impBackend :: Backend
                     , curDevice  :: Device
                     , curLevel   :: ParallelismLevel }
data ImpCatEnv = ImpCatEnv
  { envRefDests   :: Env Dest
  , envPtrsToFree :: [IExpr]
  , envScope      :: Scope
  , envStatements :: [ImpStatement]
  , envFunctions  :: Env ImpFunction }

type ImpM = ReaderT ImpCtx (Cat ImpCatEnv)
type AtomRecon = Abs (Nest Binder) Atom

toImpModule :: Backend -> Block -> (ImpModule, [LitVal], AtomRecon)
toImpModule backend block = runImpMBinders initOpts argBinders $ do
  (reconAtom, impBlock) <- scopedBlock $ translateTopLevel block'
  functions <- toList <$> looks envFunctions
  let ty = IFunType EntryFun (map binderAnn argBinders) (impBlockType impBlock)
  let mainFunction = ImpFunction (impMainFunName:>ty) argBinders impBlock
  return (ImpModule (functions ++ [mainFunction]), argVals, reconAtom)
  where
    (argBinders, argVals, block') = abstractPtrLiterals block
    initOpts = ImpCtx backend CPU TopLevel

runImpMBinders :: ImpCtx -> [IBinder] -> ImpM a -> a
runImpMBinders opts inBinders m = runImpM opts inVarScope m
  where
    inVarScope :: Scope  -- TODO: fix (shouldn't use UnitTy)
    inVarScope = foldMap binderAsEnv $ fmap (fmap $ const (UnitTy, UnknownBinder)) inBinders

translateTopLevel :: Block -> ImpM (AtomRecon, [IExpr])
translateTopLevel block = do
  outDest <- allocKind Unmanaged $ getType block
  void $ translateBlock mempty (Just outDest, block)
  resultAtom <- destToAtom outDest
  let vsOut = envAsVars $ freeVars resultAtom
  let reconAtom = Abs (toNest $ [Bind (v:>ty) | (v:>(ty, _)) <- vsOut]) resultAtom
  let resultIExprs = [IVar (v:>fromScalarType ty) | (v:>(ty, _)) <- vsOut]
  return (reconAtom, resultIExprs)

runImpM :: ImpCtx -> Scope -> ImpM a -> a
runImpM opts inVarScope m =
  fst $ runCat (runReaderT m opts) $ mempty {envScope = inVarScope}

translateBlock :: SubstEnv -> WithDest Block -> ImpM Atom
translateBlock env destBlock = do
  let (decls, result, copies) = splitDest destBlock
  env' <- (env<>) <$> catFoldM translateDecl env decls
  forM_ copies $ \(dest, atom) -> copyAtom dest =<< impSubst env' atom
  translateExpr env' result

translateDecl :: SubstEnv -> WithDest Decl -> ImpM SubstEnv
translateDecl env (maybeDest, (Let _ b bound)) = do
  b' <- traverse (impSubst env) b
  ans <- translateExpr env (maybeDest, bound)
  return $ b' @> ans
translateDecl env (maybeDest, (Unpack bs bound)) = do
  bs' <- mapM (traverse (impSubst env)) bs
  expr <- translateExpr env (maybeDest, bound)
  case expr of
    DataCon _ _ _ ans -> return $ newEnv bs' ans
    Record items -> return $ newEnv bs $ toList items
    _ -> error "Unsupported type in an Unpack binding"

translateExpr :: SubstEnv -> WithDest Expr -> ImpM Atom
translateExpr env (maybeDest, expr) = case expr of
  Hof hof@(For _ _) -> do
    -- TODO: Add support for reductions
    -- TODO: Not every parallel for can be made a kernel, since we don't
    --       lift large allocations just yet.
    backend <- asks impBackend
    level   <- asks curLevel
    if level == TopLevel && backend `elem` [LLVMCUDA, LLVMMC] && isPure expr
      then launchKernel env (maybeDest, hof)
      else toImpHof env (maybeDest, hof)
  Hof hof -> toImpHof env (maybeDest, hof)
  App x' idx' -> case getType x' of
    TabTy _ _ -> do
      x <- impSubst env x'
      idx <- impSubst env idx'
      case x of
        Lam a@(Abs _ (TabArrow, _)) ->
          translateBlock mempty (maybeDest, snd $ applyAbs a idx)
        _ -> error $ "Invalid Imp atom: " ++ pprint x
    _ -> error $ "shouldn't have non-table app left"
  Atom x   -> copyDest maybeDest =<< impSubst env x
  Op   op  -> toImpOp . (maybeDest,) =<< traverse (impSubst env) op
  Case e alts _ -> do
    e' <- impSubst env e
    case e' of
      DataCon _ _ con args -> do
        let Abs bs body = alts !! con
        translateBlock (env <> newEnv bs args) (maybeDest, body)
      Variant (NoExt types) label i x -> do
        let LabeledItems ixtypes = enumerate types
        let index = fst $ ixtypes M.! label NE.!! i
        let Abs bs body = alts !! index
        translateBlock (env <> newEnv bs [x]) (maybeDest, body)
      Con (SumAsProd _ tag xss) -> do
        let tag' = fromScalarAtom tag
        dest <- allocDest maybeDest $ getType expr
        emitSwitch tag' $ flip map (zip xss alts) $
          \(xs, Abs bs body) ->
             void $ translateBlock (env <> newEnv bs xs) (Just dest, body)
        destToAtom dest
      _ -> error $ "Unexpected scrutinee: " ++ pprint e'

launchKernel :: SubstEnv -> WithDest Hof -> ImpM Atom
launchKernel env (maybeDest, ~hof@(For _ (LamVal b body))) = do
  opts  <- ask
  idxTy <- impSubst env $ binderType b
  n     <- indexSetSize idxTy
  dest  <- allocDest maybeDest $ getType $ Hof hof
  i <- freshVar (binderNameHint b:>getIType n)
  let (cc, dev) = case impBackend opts of
        LLVMCUDA -> (CUDAKernelLaunch, GPU)
        LLVMMC   -> (MCThreadLaunch  , CPU)
        backend -> error $ "Shouldn't be launching kernels from " ++ show backend
  kernelBody <- withDevice dev $ withLevel ThreadLevel $ scopedVoidBlock $ do
    idx <- intToIndex idxTy $ IVar i
    ithDest <- destGet dest idx
    void $ translateBlock (env <> b @> idx) (Just ithDest, body)
  let args = envAsVars $ freeIVars kernelBody `envDiff` (i @> ())
  f <- emitFunction cc (map Bind (i:args)) kernelBody
  emitStatement $ ILaunch f n $ map IVar args
  destToAtom dest

impMainFunName :: Name
impMainFunName = Name TopFunctionName "impMain" 0

emitFunction :: CallingConvention -> [IBinder] -> ImpBlock -> ImpM IFunVar
emitFunction cc bs body = do
  funEnv <- looks envFunctions
  let name = genFresh (Name TopFunctionName "kernel" 0) funEnv
  let fvar = name :> IFunType cc (map binderAnn bs) (impBlockType body)
  extend $ mempty {envFunctions = fvar @> ImpFunction fvar bs body}
  return fvar

impSubst :: Subst a => SubstEnv -> a -> ImpM a
impSubst env x = do
  scope <- variableScope
  return $ subst (env, scope) x

toImpOp :: WithDest (PrimOp Atom) -> ImpM Atom
toImpOp (maybeDest, op) = case op of
  TabCon (TabTy b _) rows -> do
    dest <- allocDest maybeDest resultTy
    forM_ (zip [0..] rows) $ \(i, row) -> do
      ithDest <- destGet dest =<< intToIndex (binderType b) (IIdxRepVal i)
      copyAtom ithDest row
    destToAtom dest
  Fst ~(PairVal x _) -> returnVal x
  Snd ~(PairVal _ y) -> returnVal y
  PrimEffect ~(Var refVar) m -> do
    refDest <- getRef refVar
    case m of
      MAsk    -> returnVal =<< destToAtom refDest
      MTell x -> addToAtom  refDest x >> returnVal UnitVal
      MPut x  -> copyAtom   refDest x >> returnVal UnitVal
      MGet -> do
        dest <- allocDest maybeDest resultTy
        -- It might be more efficient to implement a specialized copy for dests
        -- than to go through a general purpose atom.
        copyAtom dest =<< destToAtom refDest
        destToAtom dest
  IntAsIndex n i -> do
    let i' = fromScalarAtom i
    n' <- indexSetSize n
    cond <- emitInstr $ IPrimOp $ ScalarBinOp (ICmp Less) i' n'
    cond' <- cast cond tagBT
    emitSwitch cond' [emitStatement $ IInstr (Nothing, IThrowError), return ()]
    returnVal =<< intToIndex resultTy i'
    where (BaseTy tagBT) = TagRepTy
  IdxSetSize n -> returnVal . toScalarAtom  =<< indexSetSize n
  IndexAsInt idx -> asInt $ case idx of
      Con (AnyValue t) -> anyValue t
      _                -> idx
    where
      asInt a = case a of
        Con (IntRangeVal   _ _   i) -> returnVal $ i
        Con (IndexRangeVal _ _ _ i) -> returnVal $ i
        _ -> returnVal . toScalarAtom =<< indexToInt idx
  Inject e -> do
    let (TC (IndexRange t low _)) = getType e
    offset <- case low of
      InclusiveLim a -> indexToInt a
      ExclusiveLim a -> indexToInt a >>= iaddI (IIdxRepVal 1)
      Unlimited      -> return (IIdxRepVal 0)
    restrictIdx <- indexToInt e
    idx <- iaddI restrictIdx offset
    returnVal =<< intToIndex t idx
  IndexRef ~(Var refVar@(_:>(RefTy h (Pi a)))) i -> do
    refDest    <- getRef refVar
    subrefDest <- destGet refDest i
    subrefVar  <- freshVar (varName refVar :> RefTy h (snd $ applyAbs a i))
    putRef subrefVar subrefDest
    returnVal $ Var subrefVar
  FstRef ~(Var refVar@(_:>(RefTy h (PairTy a _)))) -> do
    ~(ConDest (PairCon ref _)) <- getRef refVar
    subrefVar <- freshVar (varName refVar :> RefTy h a)
    putRef subrefVar ref
    returnVal $ Var subrefVar
  SndRef ~(Var refVar@(_:>(RefTy h (PairTy _ b)))) -> do
    ~(ConDest (PairCon _ ref)) <- getRef refVar
    subrefVar <- freshVar (varName refVar :> RefTy h b)
    putRef subrefVar ref
    returnVal $ Var subrefVar
  PtrOffset arr off -> do
    buf <- impOffset (fromScalarAtom arr) (fromScalarAtom off)
    returnVal $ toScalarAtom buf
  PtrLoad arr -> returnVal . toScalarAtom =<< loadAnywhere (fromScalarAtom arr)
  SliceOffset ~(Con (IndexSliceVal n l tileOffset)) idx -> do
    i' <- indexToInt idx
    i <- iaddI (fromScalarAtom tileOffset) i'
    returnVal =<< intToIndex n i
  SliceCurry ~(Con (IndexSliceVal _ (PairTy u v) tileOffset)) idx -> do
    vz <- intToIndex v $ IIdxRepVal 0
    extraOffset <- indexToInt (PairVal idx vz)
    tileOffset' <- iaddI (fromScalarAtom tileOffset) extraOffset
    returnVal $ toScalarAtom tileOffset'
  ThrowError ty -> do
    emitStatement $ IInstr (Nothing, IThrowError)
    return $ Con $ AnyValue ty
  CastOp destTy x -> case (getType x, destTy) of
    (BaseTy _, BaseTy bt) -> returnVal =<< toScalarAtom <$> cast (fromScalarAtom x) bt
    _ -> error $ "Invalid cast: " ++ pprint (getType x) ++ " -> " ++ pprint destTy
  Select p x y -> do
    dest <- allocDest maybeDest resultTy
    p' <- cast (fromScalarAtom p) tagBT
    emitSwitch p' [copyAtom dest y, copyAtom dest x]
    destToAtom dest
    where (BaseTy tagBT) = TagRepTy
  RecordCons   _ _ -> error "Unreachable: should have simplified away"
  RecordSplit  _ _ -> error "Unreachable: should have simplified away"
  VariantLift  _ _ -> error "Unreachable: should have simplified away"
  VariantSplit _ _ -> error "Unreachable: should have simplified away"
  _ -> do
    returnVal . toScalarAtom =<< emitInstr (IPrimOp $ fmap fromScalarAtom op)
  where
    resultTy = getType $ Op op
    returnVal atom = case maybeDest of
      Nothing   -> return atom
      Just dest -> copyAtom dest atom >> return atom

toImpHof :: SubstEnv -> WithDest Hof -> ImpM Atom
toImpHof env (maybeDest, hof) = do
  resultTy <- impSubst env $ getType $ Hof hof
  case hof of
    For d (LamVal b body) -> do
      idxTy <- impSubst env $ binderType b
      n' <- indexSetSize idxTy
      dest <- allocDest maybeDest resultTy
      emitLoop (binderNameHint b) d n' $ \i -> do
        idx <- intToIndex idxTy i
        ithDest <- destGet dest idx
        void $ translateBlock (env <> b @> idx) (Just ithDest, body)
      destToAtom dest
    -- Tile d (LamVal tb tBody) (LamVal sb sBody) -> do
    --   ~(TC (IndexSlice idxTy tileIdxTy)) <- impSubst env $ binderType tb
    --   n <- indexSetSize idxTy
    --   dest <- allocDest maybeDest resultTy
    --   tileLen <- indexSetSize tileIdxTy
    --   nTiles      <- n `idivI` tileLen
    --   epilogueOff <- nTiles `imulI` tileLen
    --   nEpilogue   <- n `isubI` epilogueOff
    --   emitLoop (binderNameHint tb) Fwd nTiles $ \iTile -> do
    --     tileOffset <- toScalarAtom <$> iTile `imulI` tileLen
    --     let tileAtom = Con $ IndexSliceVal idxTy tileIdxTy tileOffset
    --     tileDest <- destSliceDim dest d tileOffset tileIdxTy
    --     void $ translateBlock (env <> tb @> tileAtom) (Just tileDest, tBody)
    --   emitLoop (binderNameHint sb) Fwd nEpilogue $ \iEpi -> do
    --     i <- iEpi `iaddI` epilogueOff
    --     idx <- intToIndex idxTy i
    --     sDest <- destGetDim dest d idx
    --     void $ translateBlock (env <> sb @> idx) (Just sDest, sBody)
    --   destToAtom dest
    While (Lam (Abs _ (_, cond))) (Lam (Abs _ (_, body))) -> do
      cond' <- liftM snd $ scopedBlock $ do
                 ans <- translateBlock env (Nothing, cond)
                 return ((), [fromScalarAtom ans])
      body' <- scopedVoidBlock $ void $ translateBlock env (Nothing, body)
      emitStatement $ IWhile cond' body'
      return UnitVal
    RunReader r (BinaryFunVal _ ref _ body) -> do
      rDest <- alloc $ getType r
      rVar  <- freshVar $ fromBind "ref" ref
      copyAtom rDest =<< impSubst env r
      localRef rVar rDest $
        translateBlock (env <> ref @> Var rVar) (maybeDest, body)
    RunWriter (BinaryFunVal _ ref _ body) -> do
      (aDest, wDest) <- destPairUnpack <$> allocDest maybeDest resultTy
      let RefTy _ wTy = getType ref
      copyAtom wDest (zeroAt wTy)
      wVar <- freshVar $ fromBind "ref" ref
      void $ localRef wVar wDest $
        translateBlock (env <> ref @> Var wVar) (Just aDest, body)
      PairVal <$> destToAtom aDest <*> destToAtom wDest
    RunState s (BinaryFunVal _ ref _ body) -> do
      (aDest, sDest) <- destPairUnpack <$> allocDest maybeDest resultTy
      copyAtom sDest =<< impSubst env s
      sVar <- freshVar $ fromBind "ref" ref
      void $ localRef sVar sDest $
        translateBlock (env <> ref @> Var sVar) (Just aDest, body)
      PairVal <$> destToAtom aDest <*> destToAtom sDest
    _ -> error $ "Invalid higher order function primitive: " ++ pprint hof
  where
    localRef refVar refDest m = withRefScope $ putRef refVar refDest >> m

abstractPtrLiterals :: Block -> ([IBinder], [LitVal], Block)
abstractPtrLiterals block = flip evalState initState $ do
  block' <- traverseLiterals block $ \val -> case val of
    PtrLit ty ptr -> do
      ptrName <- gets $ M.lookup (ty, ptr). fst
      case ptrName of
        Just v -> return $ Var $ v :> getType (Con $ Lit val)
        Nothing -> do
          (varMap, usedNames) <- get
          let name = genFresh (Name AbstractedPtrName "ptr" 0) usedNames
          put ( varMap    <> M.insert (ty, ptr) name varMap
              , usedNames <> (name @> ()))
          return $ Var $ name :> BaseTy (PtrType ty)
    _ -> return $ Con $ Lit val
  valsAndNames <- gets $ M.toAscList . fst
  let impBinders = [Bind (name :> PtrType ty ) | ((ty, _), name) <- valsAndNames]
  let vals = map (uncurry PtrLit . fst) valsAndNames
  return (impBinders, vals, block')
  where
    initState :: (M.Map (PtrType, Ptr ()) Name, Env ())
    initState = mempty

traverseLiterals :: forall m . Monad m => Block -> (LitVal -> m Atom) -> m Block
traverseLiterals block f =
  liftM fst $ flip runSubstEmbedT  mempty $ traverseBlock def block
  where
    def :: TraversalDef (SubstEmbedT m)
    def = (traverseDecl def, traverseExpr def, traverseAtomLiterals)

    traverseAtomLiterals :: Atom -> SubstEmbedT m Atom
    traverseAtomLiterals atom = case atom of
      Con (Lit x) -> lift $ lift $ f x
      _ -> traverseAtom def atom

-- === Destination type ===

data Dest = BaseTypeDest Atom  -- all in-scope indices implicitly applied
          | TabDest (Abs Binder Dest)
          | DataConDest DataDef [Atom] [Dest]
          | RecordDest (LabeledItems Dest)
          | ConDest (PrimCon Dest)
          | ConstDest Atom  -- used for statically-known data like types
            deriving (Show)

type WithDest a = (Maybe Dest, a)

instance HasType Dest where
  typeCheck dest = case dest of
    BaseTypeDest ptr -> do
      PtrTy (_, _, a) <- typeCheck ptr
      return $ BaseTy a
    TabDest (Abs b body) -> do
      bodyTy <- withBinder b $ typeCheck body
      return $ TabTy b bodyTy
    DataConDest def params args -> undefined
    RecordDest xs -> undefined
    ConDest con -> case con of
      CharCon v -> v |: (BaseTy $ Scalar Int8Type) $> CharTy
      PairCon x y -> PairTy <$> typeCheck x <*> typeCheck y
      UnitCon -> return UnitTy
      SumAsProd (ConstDest ty) tag _ -> tag |:TagRepTy >> return ty
      IntRangeVal (ConstDest l) (ConstDest h) i ->
        i|:IdxRepTy >> return (TC $ IntRange l h)
      IndexRangeVal (ConstDest t) l h i -> do
        i|:IdxRepTy
        return (TC $ IndexRange t (fmap fromConstDest l) (fmap fromConstDest h))
        where fromConstDest (ConstDest x) = x
      _ -> throw CompilerErr $ "Not a valid dest constructor: " ++ pprint dest
    ConstDest x -> typeCheck x

instance HasVars Dest where
  freeVars dest = case dest of
    BaseTypeDest x -> freeVars x
    TabDest tab -> freeVars tab
    DataConDest _ params args -> freeVars params <> freeVars args
    RecordDest xs -> freeVars xs
    ConDest con -> foldMap freeVars con
    ConstDest x -> freeVars x

instance Subst Dest where
  subst env dest = case dest of
    BaseTypeDest x -> BaseTypeDest $ subst env x
    TabDest tab -> TabDest $ subst env tab
    DataConDest def params args -> DataConDest def (subst env params) (subst env args)
    RecordDest xs -> RecordDest $ subst env xs
    ConDest con -> ConDest $ fmap (subst env) con
    ConstDest x -> ConstDest $ subst env x

destPairUnpack :: Dest -> (Dest, Dest)
destPairUnpack (ConDest (PairCon l r)) = (l, r)
destPairUnpack d = error $ "Not a pair destination: " ++ show d

fromIVar :: IExpr -> IVar
fromIVar ~(IVar v) = v

-- TODO: combine destGet and destGetCore using a typeclass for monads that
-- expose enough operations to do index arithmetic
destGetCore :: Dest -> Atom -> SubstEmbedT ImpM Dest
destGetCore (TabDest (Abs b body)) i = destGetCoreRec (b@>i) (Nest b Empty) body i

destGetCoreRec :: Env Atom -> IndexStructure -> Dest -> Atom -> SubstEmbedT ImpM Dest
destGetCoreRec env idxs dest i = case dest of
  TabDest (Abs b body) ->
    (TabDest . Abs b') <$> destGetCoreRec env (idxs <> Nest b Empty) body i
    where b' = scopelessSubst env b
  BaseTypeDest ptr -> do
    ordinal <- indexToIntE i
    offset <- offsetToE idxs ordinal
    BaseTypeDest <$> ptrOffset ptr offset
  ConDest con -> ConDest <$> traverse (\d -> destGetCoreRec env idxs d i) con
  ConstDest x -> return $ ConstDest x

destGet :: Dest -> Atom -> ImpM Dest
destGet (TabDest (Abs b body)) i = destGetRec (b@>i) (Nest b Empty) body i

destGetRec :: Env Atom -> IndexStructure -> Dest -> Atom -> ImpM Dest
destGetRec env idxs dest i = case dest of
  TabDest (Abs b body) -> do
    (TabDest . Abs b') <$> destGetRec env (idxs <> Nest b Empty) body i
    where b' = scopelessSubst env b
  BaseTypeDest ptr -> do
    ordinal <- indexToInt i
    offset <- liftM fromScalarAtom $ fromEmbed $ offsetToE idxs $ toScalarAtom ordinal
    (BaseTypeDest . toScalarAtom) <$> impOffset (fromScalarAtom ptr) offset
  ConDest con -> ConDest <$> traverse (\d -> destGetRec env idxs d i) con
  ConstDest x -> return $ ConstDest x

-- destSliceDim :: Dest -> Int -> Atom -> Type -> ImpM Dest
-- destSliceDim = undefined
-- destSliceDim dest dim fromOrdinal idxTy = indexDest dest dim $ \(Dest d) -> case d of
--   TabVal b _ -> do
--     lam <- buildLam (Bind (binderNameHint b :> idxTy)) TabArrow $ \idx -> do
--       i <- indexToIntE idx
--       ioff <- iadd i fromOrdinal
--       vidx <- intToIndexE (binderType b) ioff
--       appReduce d vidx
--     return $ Dest $ lam
--   _ -> error "Slicing a non-array dest"

-- indexDest :: Dest -> Int -> (Dest -> EmbedT ImpM Dest) -> ImpM Dest
-- indexDest = undefined
-- indexDest (Dest destAtom) dim f = do
--   scope <- variableScope
--   (block, _) <- runEmbedT (buildScoped $ go dim destAtom) scope
--   Dest <$> translateBlock mempty (Nothing, block)
--   where
--     go 0 dest = coerce <$> f (Dest dest)
--     go d da@(TabVal v _) = buildLam v TabArrow $ \v' -> go (d-1) =<< appReduce da v'
--     go _ _ = error $ "Indexing a non-array dest"

-- XXX: This should only be called when it is known that the dest will _never_
--      be modified again, because it doesn't copy the state!
destToAtom :: Dest -> ImpM Atom
destToAtom dest = do
  scope <- variableScope
  (atom, (_, decls)) <- runSubstEmbedT (destToBlock dest) scope
  translateBlock mempty $ (Nothing, Block decls $ Atom atom)

destToBlock :: Dest -> SubstEmbedT ImpM Atom
destToBlock dest = case dest of
  BaseTypeDest ptr -> lift $ ptrLoad ptr
  TabDest (Abs b _) -> buildLam b TabArrow $ \i ->
    destToBlock =<< destGetCore dest i
  DataConDest def params xs -> DataCon def params 0 <$> mapM destToBlock xs
  ConDest con -> Con <$> traverse destToBlock con
  ConstDest x -> return x

splitDest :: WithDest Block -> ([WithDest Decl], WithDest Expr, [(Dest, Atom)])
splitDest (maybeDest, (Block decls ans)) = do
  case (maybeDest, ans) of
    (Just dest, Atom atom) ->
      let (gatherCopies, varDests) = runState (execWriterT $ gatherVarDests dest atom) mempty
          -- If any variable appearing in the ans atom is not defined in the
          -- current block (e.g. it comes from the surrounding block), then we need
          -- to do the copy explicitly, as there is no let binding that will use it
          -- as the destination.
          blockVars = foldMap (\(Let _ b _) -> b @> ()) decls
          closureCopies = fmap (\(n, (d, t)) -> (d, Var $ n :> t))
                               (envPairs $ varDests `envDiff` blockVars) in
        ( fmap (\d@(Let _ b _) -> (fst <$> varDests `envLookup` b, d)) $ toList decls
        , (Nothing, ans)
        , gatherCopies ++ closureCopies)
    _ -> (fmap (Nothing,) $ toList decls, (maybeDest, ans), [])
  where
    -- Maps all variables used in the result atom to their respective destinations.
    gatherVarDests :: Dest -> Atom -> WriterT [(Dest, Atom)] (State (Env (Dest, Type))) ()
    gatherVarDests dest result = case (dest, result) of
      (_, Var v) -> do
        dests <- get
        case dests `envLookup` v of
          Nothing -> modify $ (<> (v @> (dest, varType v)))
          Just _  -> tell [(dest, result)]
      -- If the result is a table lambda then there is nothing we can do, except for a copy.
      (_, TabVal _ _)  -> tell [(dest, result)]
      (_, Con (Lit _)) -> tell [(dest, result)]
      (DataConDest _ _ dests, DataCon _ _ _ args)
        | length dests == length args -> do
            zipWithM_ gatherVarDests dests args
      (RecordDest items, Record items')
        | fmap (const ()) items == fmap (const ()) items' -> do
            zipWithM_ gatherVarDests (toList items) (toList items')
      (ConDest (SumAsProd _ _ _), _) -> tell [(dest, result)]  -- TODO
      (ConDest (PairCon ld rd), PairVal lr rr ) -> gatherVarDests ld lr >>
                                                   gatherVarDests rd rr
      (ConDest UnitCon, UnitVal) -> return ()
      _ -> unreachable
      where
        unreachable = error $ "Invalid dest-result pair:\n"
                        ++ pprint dest ++ "\n  and:\n" ++ pprint result

copyDest :: Maybe Dest -> Atom -> ImpM Atom
copyDest maybeDest atom = case maybeDest of
  Nothing   -> return atom
  Just dest -> copyAtom dest atom >> return atom

allocDest :: Maybe Dest -> Type -> ImpM Dest
allocDest maybeDest t = case maybeDest of
  Nothing   -> alloc t
  Just dest -> return dest

makeAllocDest :: AllocType -> Name -> Type -> ImpM Dest
makeAllocDest allocTy hint destType = do
  scope <- variableScope
  flip runReaderT (mempty, scope) $ makeAllocDestRec hint allocTy Empty destType

makeAllocDestRec :: Name -> AllocType -> IndexStructure -> Type
                 -> ReaderT ScopedSubstEnv ImpM Dest
makeAllocDestRec hint allocTy idxs ty = case ty of
  TabTy b bodyTy -> do
    substEnv@(_, scope) <- ask
    let (b', substEnv') = renameBinder "i" scope $ subst substEnv b
    dest <- extendR substEnv' $ makeAllocDestRec hint allocTy
              (idxs <> Nest b' Empty) bodyTy
    return $ TabDest $ Abs b' dest
  TypeCon def params -> do
    let dcs = applyDataDefParams def params
    case dcs of
      [] -> error "Void type not allowed"
      [DataConDef _ bs] -> do
        dests <- mapM (rec . binderType) $ toList bs
        return $ DataConDest def params dests
      _ -> do
        tag <- rec TagRepTy
        let dcs' = applyDataDefParams def params
        contents <- forM dcs' $ \(DataConDef _ bs) -> forM (toList bs) (rec . binderType)
        return $ ConDest $ SumAsProd (ConstDest ty) tag contents
  RecordTy (NoExt types) -> RecordDest <$> forM types rec
  VariantTy (NoExt types) -> do
    tag <- rec TagRepTy
    contents <- forM (toList types) rec
    return $ ConDest $ SumAsProd (ConstDest ty) tag $ map (\x->[x]) contents
  TC con -> case con of
    BaseType b -> lift $ do
      numel <- elemCount idxs
      ptr <- chooseAddrSpaceAndAllocate hint allocTy b numel
      return $ BaseTypeDest $ toScalarAtom ptr
    PairType a b     -> ConDest <$> (PairCon <$> rec a <*> rec b)
    UnitType         -> return $ ConDest $ UnitCon
    CharType         -> (ConDest . CharCon) <$> rec (BaseTy $ Scalar Int8Type)
    IntRange     l h -> (ConDest . IntRangeVal (c l) (c h)) <$> rec IdxRepTy
    IndexRange t l h -> (ConDest . IndexRangeVal (c t) (fmap c l) (fmap c h)) <$> rec IdxRepTy
  _ -> error $ "Not implemented: " ++ pprint ty
  where
    rec = makeAllocDestRec hint allocTy idxs
    c = ConstDest

chooseAddrSpaceAndAllocate :: Name -> AllocType -> BaseType -> IExpr -> ImpM IExpr
chooseAddrSpaceAndAllocate nameHint allocTy b numel = do
  backend  <- asks impBackend
  curDev   <- asks curDevice
  mainDev  <- getMainDevice
  let (addrSpace, mustFree) = case allocTy of
        Managed | curDev == mainDev -> if isSmall numel
                                         then (Stack, False)
                                         else (Heap mainDev, True)
                | otherwise -> (Heap mainDev, False)
        Unmanaged           -> (Heap mainDev, False)
  allocateBuffer nameHint addrSpace mustFree b numel

isSmall :: IExpr -> Bool
isSmall numel = case numel of
  ILit l | n <= 256 -> True
    where n = getIntLit l
  _                 -> False

allocateBuffer :: Name -> AddressSpace -> Bool -> BaseType -> IExpr -> ImpM IExpr
allocateBuffer nameHint addrSpace mustFree b numel = do
  buffer <- freshVar (nameHint :> PtrType (AllocatedPtr, addrSpace, b))
  emitAlloc buffer numel
  when mustFree $ extendAlloc $ IVar buffer
  return $ IVar buffer

getMainDevice :: ImpM Device
getMainDevice = do
  backend <- asks impBackend
  return $ case backend of
    LLVM     -> CPU
    LLVMMC   -> CPU
    LLVMCUDA -> GPU
    Interp   -> error "Shouldn't be compiling with interpreter backend"

-- TODO: separate these concepts in IFunType?
deviceFromCallingConvention :: CallingConvention -> Device
deviceFromCallingConvention cc = case cc of
  OrdinaryFun      -> CPU
  EntryFun         -> CPU
  MCThreadLaunch   -> CPU
  CUDAKernelLaunch -> GPU

-- === Atom <-> IExpr conversions ===

fromScalarAtom :: HasCallStack => Atom -> IExpr
fromScalarAtom atom = case atom of
  Var (v:>BaseTy b) -> IVar (v :> b)
  Con (Lit x)       -> ILit x
  _ -> error $ "Expected scalar, got: " ++ pprint atom

toScalarAtom :: IExpr -> Atom
toScalarAtom ie = case ie of
  ILit l -> Con $ Lit l
  IVar (v:>b) -> Var (v:>BaseTy b)

fromScalarType :: Type -> IType
fromScalarType (BaseTy b) =  b
fromScalarType ty = error $ "Not a scalar type: " ++ pprint ty

toScalarType :: IType -> Type
toScalarType b = BaseTy b

-- === Type classes ===

fromEmbed :: Embed Atom -> ImpM Atom
fromEmbed m = do
  scope <- variableScope
  translateBlock mempty (Nothing, fst $ runEmbed (buildScoped m) scope)

intToIndex :: Type -> IExpr -> ImpM Atom
intToIndex ty i = fromEmbed (intToIndexE ty (toScalarAtom i))

indexToInt :: Atom -> ImpM IExpr
indexToInt idx = fromScalarAtom <$> fromEmbed (indexToIntE idx)

indexSetSize :: Type -> ImpM IExpr
indexSetSize ty = fromScalarAtom <$> fromEmbed (indexSetSizeE ty)

elemCount :: IndexStructure -> ImpM IExpr
elemCount idxs = fromScalarAtom <$> fromEmbed (elemCountE idxs)

elemCountE :: MonadEmbed m => IndexStructure -> m Atom
elemCountE idxs = case idxs of
  Empty    -> return $ IdxRepVal 1
  Nest b _ -> offsetToE idxs =<< indexSetSizeE (binderType b)

offsetToE :: HasCallStack => MonadEmbed m => IndexStructure -> Atom -> m Atom
offsetToE idxs i = A.evalSumClampPolynomial (A.offsets idxs) i

copyAtom :: HasCallStack => Dest -> Atom -> ImpM ()
copyAtom dest src | getType dest /= getType src = error $ "Type mismatch " ++
                                                    pprint dest ++ " /= " ++ pprint src
copyAtom dest src = case (dest, src) of
  (BaseTypeDest ptr, x) -> store (fromScalarAtom ptr) (fromScalarAtom x)
  (TabDest _, TabVal _ _) -> zipTabDestAtom copyAtom dest src
  (ConDest (SumAsProd _ tag payload), DataCon _ _ con x) -> do
    copyAtom tag (TagRepVal $ fromIntegral con)
    zipWithM_ copyAtom (payload !! con) x
  (RecordDest items, Record items')
    | fmap (const ()) items == fmap (const ()) items' -> do
        zipWithM_ copyAtom (toList items) (toList items')
  (ConDest (SumAsProd _ tag payload), Variant (NoExt types) label i x) -> do
    let LabeledItems ixtypes = enumerate types
    let index = fst $ (ixtypes M.! label) NE.!! i
    copyAtom tag (TagRepVal $ fromIntegral index)
    zipWithM_ copyAtom (payload !! index) [x]

  (ConDest destCon, Con srcCon) -> void $ zipWithConM copyAtom destCon srcCon
  (ConstDest _, _) -> return ()  -- TODO: could check that they're equal?
  _ -> error $ "Not implemented " ++ pprint (dest, src)

zipTabDestAtom :: HasCallStack => (Dest -> Atom -> ImpM ()) -> Dest -> Atom -> ImpM ()
zipTabDestAtom f ~dest@(TabDest (Abs b _)) ~src@(TabVal b' _) = do
  unless (binderType b == binderType b') $ error $ "Mismatched dimensions"
  let idxTy = binderType b
  n <- indexSetSize idxTy
  emitLoop "i" Fwd n $ \i -> do
    idx <- intToIndex idxTy i
    destIndexed <- destGet dest idx
    srcIndexed  <- translateExpr mempty (Nothing, App src idx)
    f destIndexed srcIndexed

zipWithConM :: Monad m => (a -> b -> m c)
            -> PrimCon a -> PrimCon b -> m (PrimCon c)
zipWithConM f con1 con2 = case (con1, con2) of
  (PairCon x y, PairCon x' y') -> PairCon <$> f x x' <*> f y y'
  (UnitCon    , UnitCon      ) -> return UnitCon
  (SumAsProd ty tag xs, SumAsProd ty' tag' xs') -> do
    tag'' <- f tag tag'
    xs''  <- zipWithM (zipWithM f) xs xs'
    ty''  <- f ty ty'
    return $ SumAsProd ty'' tag'' xs''
  (CharCon x, CharCon x') -> CharCon <$> f x x'
  (IntRangeVal x y z, IntRangeVal x' y' z') ->
    IntRangeVal <$> f x x' <*> f y y' <*> f z z'
  (IndexRangeVal x y z w, IndexRangeVal x' y' z' w') ->
    IndexRangeVal <$> f x x' <*> zipWithLimM f y y' <*> zipWithLimM f z z' <*> f w w'
  _ -> unreachable
  where
    unreachable = error $ "Not an imp atom, or mismatched dest"

zipWithLimM :: Monad m => (a -> b -> m c) -> Limit a -> Limit b -> m (Limit c)
zipWithLimM = undefined

-- TODO: put this in userspace using type classes
addToAtom :: Dest -> Atom -> ImpM ()
addToAtom dest src = case (dest, src) of
  (BaseTypeDest ptr, x) -> do
    let ptr' = fromScalarAtom ptr
    let x'   = fromScalarAtom x
    cur <- load ptr'
    let op = case getIType cur of
               Scalar _ -> ScalarBinOp
               Vector _ -> VectorBinOp
               _ -> error $ "The result of load cannot be a reference"
    updated <- emitInstr $ IPrimOp $ op FAdd cur x'
    store ptr' updated
  (TabDest _, TabVal _ _) -> zipTabDestAtom addToAtom dest src
  (ConDest destCon, Con srcCon) -> void $ zipWithConM addToAtom destCon srcCon
  (ConstDest _, _) -> return ()
  _ -> error $ "Not implemented " ++ pprint (dest, src)

loadAnywhere :: IExpr -> ImpM IExpr
loadAnywhere ptr = do
  curDev <- asks curDevice
  let (PtrType (_, addrSpace, ty)) = getIType ptr
  case addrSpace of
    Heap ptrDev | ptrDev /= curDev -> do
      localPtr <- allocateStackSingleton ty
      memcopy localPtr ptr (IIdxRepVal 1)
      load localPtr
    _ -> load ptr

storeAnywhere :: IExpr -> IExpr -> ImpM ()
storeAnywhere ptr val = do
  curDev <- asks curDevice
  let (PtrType (_, addrSpace, ty)) = getIType ptr
  case addrSpace of
    Heap ptrDev | ptrDev /= curDev -> do
      localPtr <- allocateStackSingleton ty
      store localPtr val
      memcopy ptr localPtr (IIdxRepVal 1)
    _ -> store ptr val

allocateStackSingleton :: IType -> ImpM IExpr
allocateStackSingleton ty = allocateBuffer "tmp" Stack False ty (IIdxRepVal 1)

-- === Imp embedding ===

embedBinOp :: (Atom -> Atom -> Embed Atom) -> (IExpr -> IExpr -> ImpM IExpr)
embedBinOp f x y =
  fromScalarAtom <$> fromEmbed (f (toScalarAtom x) (toScalarAtom y))

iaddI :: IExpr -> IExpr -> ImpM IExpr
iaddI = embedBinOp iadd

isubI :: IExpr -> IExpr -> ImpM IExpr
isubI = embedBinOp isub

imulI :: IExpr -> IExpr -> ImpM IExpr
imulI = embedBinOp imul

idivI :: IExpr -> IExpr -> ImpM IExpr
idivI = embedBinOp idiv

impOffset :: IExpr -> IExpr -> ImpM IExpr
impOffset ref off = emitInstr $ IPrimOp $ PtrOffset ref off

cast :: IExpr -> BaseType -> ImpM IExpr
cast x bt = emitInstr $ ICastOp bt x

load :: IExpr -> ImpM IExpr
load x = emitInstr $ IPrimOp $ PtrLoad x

memcopy :: IExpr -> IExpr -> IExpr -> ImpM ()
memcopy dest src numel = emitStatement $ IInstr (Nothing , MemCopy dest src numel)

store :: IExpr -> IExpr -> ImpM ()
store dest src = emitStatement $ IInstr (Nothing, Store dest src)

alloc :: Type -> ImpM Dest
alloc ty = allocKind Managed ty

-- TODO: Consider targeting LLVM's `switch` instead of chained conditionals.
emitSwitch :: IExpr -> [ImpM ()] -> ImpM ()
emitSwitch testIdx = rec 0
  where
    rec :: Int -> [ImpM ()] -> ImpM ()
    rec _ [] = error "Shouldn't have an empty list of alternatives"
    rec _ [body] = body
    rec curIdx (body:rest) = do
      let curTag = fromScalarAtom $ TagRepVal $ fromIntegral curIdx
      cond       <- emitInstr $ IPrimOp $ ScalarBinOp (ICmp Equal) testIdx curTag
      thisCase   <- scopedVoidBlock $ body
      otherCases <- scopedVoidBlock $ rec (curIdx + 1) rest
      emitStatement $ ICond cond thisCase otherCases

emitLoop :: Name -> Direction -> IExpr -> (IExpr -> ImpM ()) -> ImpM ()
emitLoop hint d n body = do
  (i, loopBody) <- scopedBlock $ do
    i <- freshVar (hint:>getIType n)
    body $ IVar i
    return (i, [])
  emitStatement $ IFor d (Bind i) n loopBody

emitInstr :: ImpInstr -> ImpM IExpr
emitInstr instr = do
  v <- freshVar ("v":>getIType instr)
  emitStatement $ IInstr (Just (Bind v), instr)
  return $ IVar v

data AllocType = Managed | Unmanaged

allocKind :: AllocType -> Type -> ImpM Dest
allocKind allocTy ty = makeAllocDest allocTy "v" ty

extendAlloc :: IExpr -> ImpM ()
extendAlloc v = extend $ mempty { envPtrsToFree = [v] }

emitAlloc :: IVar -> IExpr -> ImpM ()
emitAlloc v n = emitStatement $ IInstr (Just (Bind v), Alloc addr ty n)
  where PtrType (_, addr, ty) = varAnn v

scopedVoidBlock :: ImpM () -> ImpM ImpBlock
scopedVoidBlock body = liftM snd $ scopedBlock $ body $> ((),[])

scopedBlock :: ImpM (a, [IExpr]) -> ImpM (a, ImpBlock)
scopedBlock body = do
  ((aux, results), env) <- scoped body
  extend $ mempty { envScope     = envScope     env
                  , envFunctions = envFunctions env }  -- Keep the scope extension to avoid reusing variable names
  let frees = [IInstr (Nothing, Free x) | x <- envPtrsToFree env]
  return (aux, ImpBlock (toNest (envStatements env <> frees)) results)

emitStatement :: ImpStatement -> ImpM ()
emitStatement statement = extend $ mempty { envStatements = [statement] }

variableScope :: ImpM Scope
variableScope = looks envScope

freshVar :: VarP a -> ImpM (VarP a)
freshVar (hint:>t) = do
  scope <- looks envScope
  let v = genFresh (rawName GenName $ nameTag hint) scope
  extend $ mempty { envScope = v @> (UnitTy, UnknownBinder) }
  return $ v:>t

withRefScope :: ImpM a -> ImpM a
withRefScope m = do
  (a, env) <- scoped $ m
  extend $ env { envRefDests = mempty }
  return a

getRef :: Var -> ImpM Dest
getRef v = looks $ (! v) . envRefDests

putRef :: Var -> Dest -> ImpM ()
putRef v d = extend $ mempty { envRefDests = v @> d }

withLevel :: ParallelismLevel -> ImpM a -> ImpM a
withLevel level = local (\opts -> opts {curLevel = level })

withDevice :: Device -> ImpM a -> ImpM a
withDevice device = local (\opts -> opts {curDevice = device })

-- === type checking imp programs ===

-- TODO: track parallelism level and current device and add validity checks like
-- "shouldn't launch a kernel from device/thread code"

-- State keeps track of _all_ names used in the program, Reader keeps the type env.
type ImpCheckM a = StateT (Env ()) (ReaderT (Env IType, Device) (Either Err)) a

instance Checkable ImpModule where
  -- TODO: check main function defined
  checkValid (ImpModule fs) = mapM_ checkValid fs

instance Checkable ImpFunction where
  checkValid f@(ImpFunction (_:> IFunType cc _ _) bs block) = addContext ctx $ do
    let scope = foldMap (binderAsEnv . fmap (const ())) bs
    let env   = foldMap (binderAsEnv                  ) bs
    void $ flip runReaderT (env, deviceFromCallingConvention cc) $
      flip runStateT scope $ checkBlock block
    where ctx = "Checking:\n" ++ pprint f

checkBlock :: ImpBlock -> ImpCheckM [IType]
checkBlock (ImpBlock Empty val) = mapM checkIExpr val
checkBlock (ImpBlock (Nest stmt rest) val) = do
  env <- checkStatement stmt
  withTypeEnv env $ checkBlock $ ImpBlock rest val

checkStatement :: ImpStatement -> ImpCheckM (Env IType)
checkStatement stmt = addContext ctx $ case stmt of
  IInstr (binder, instr) -> do
    ty <- instrTypeChecked instr
    case (binder, ty) of
      (Nothing, Nothing) -> return mempty
      (Just _ , Nothing) -> throw CompilerErr $ "Can't assign result of void instruction"
      (Just b, Just t) -> do
        checkBinder b
        assertEq (binderAnn b) t $ "Type mismatch in instruction " ++ pprint instr
        return (b@>t)
  IFor _ i size block -> do
    checkInt size
    checkBinder i
    assertEq (binderAnn i) (getIType size) $ "Mismatch between the loop iterator and upper bound type"
    [] <- withTypeEnv (i @> getIType size) $ checkBlock block
    return mempty
  IWhile cond body -> do
    [condTy] <- checkBlock cond
    assertEq (Scalar Int8Type) condTy $ "Not a bool: " ++ pprint cond
    [] <- checkBlock body
    return mempty
  ICond predicate consequent alternative -> do
    predTy <- checkIExpr predicate
    assertEq (Scalar Int8Type) predTy "Type mismatch in predicate"
    [] <- checkBlock consequent
    [] <- checkBlock alternative
    return mempty
  ILaunch _ n args -> do
    -- TODO: check args against type of function
    assertHost
    checkInt n
    mapM_ checkIExpr args
    return mempty
  where ctx = "Checking:\n" ++ pprint stmt

instrTypeChecked :: ImpInstr -> ImpCheckM (Maybe IType)
instrTypeChecked instr = case instr of
  IPrimOp op -> Just <$> checkImpOp op
  ICastOp dt x -> do
    case getIType x of
      Scalar _ -> return ()
      _ -> throw CompilerErr $ "Invalid cast source type: " ++ pprint dt
    case dt of
      Scalar _ -> return ()
      _ -> throw CompilerErr $ "Invalid cast destination type: " ++ pprint dt
    return $ Just dt
  Alloc a ty _ -> do
    when (a /= Stack) assertHost
    return $ Just $ PtrType (AllocatedPtr, a, ty)
  MemCopy dest src numel -> do
    PtrType (_, _, destTy) <- checkIExpr dest
    PtrType (_, _, srcTy)  <- checkIExpr src
    assertEq destTy srcTy "pointer type mismatch"
    checkInt numel
    return Nothing
  Store dest val -> do
    PtrType (_, addr, ty) <- checkIExpr dest
    checkAddrAccessible addr
    valTy <- checkIExpr val
    assertEq ty valTy "Type mismatch in store"
    return Nothing
  Free _ -> return Nothing  -- TODO: check matched alloc/free
  IThrowError -> return Nothing

checkBinder :: IBinder -> ImpCheckM ()
checkBinder v = do
  scope <- get
  when (v `isin` scope) $ error $ "shadows: " ++ pprint v
  modify (<>(v@>()))

checkAddrAccessible :: AddressSpace -> ImpCheckM ()
checkAddrAccessible Stack = return ()
checkAddrAccessible (Heap device) = do
  curDevice <- asks snd
  when (device /= curDevice) $ throw CompilerErr "Address not accessible"

assertHost :: ImpCheckM ()
assertHost = do
  curDev <- asks snd
  when (curDev /= CPU) $ throw CompilerErr "Only allowed on host"

checkIExpr :: IExpr -> ImpCheckM IType
checkIExpr expr = case expr of
  ILit val -> return $ litType val
  IVar v -> asks $ (! v) . fst

checkInt :: IExpr -> ImpCheckM ()
checkInt expr = do
  bt <- checkIExpr expr
  checkIntBaseType False (BaseTy bt)

-- TODO: reuse type rules in Type.hs
checkImpOp :: IPrimOp -> ImpCheckM IType
checkImpOp op = do
  op' <- traverse checkIExpr op
  case op' of
    ScalarBinOp bop x y -> checkImpBinOp bop x y
    VectorBinOp bop x y -> checkImpBinOp bop x y
    ScalarUnOp  uop x   -> checkImpUnOp  uop x
    Select _ x y -> checkEq x y >> return x
    FFICall _ ty _ -> return ty
    VectorPack xs -> do
      Scalar ty <- return $ head xs
      mapM_ (checkEq (Scalar ty)) xs
      return $ Vector ty
    VectorIndex x i -> do
      Vector ty <- return x
      ibt       <- return i
      checkIntBaseType False $ BaseTy ibt
      return $ Scalar ty
    PtrLoad ref -> do
      PtrType (_, addr, ty) <- return ref
      checkAddrAccessible addr
      return ty
    PtrOffset ref _ -> do  -- TODO: check offset too
      PtrType (_, addr, ty) <- return ref
      return $ PtrType (DerivedPtr, addr, ty)
    _ -> error $ "Not allowed in Imp IR: " ++ pprint op
  where
    checkEq :: (Pretty a, Show a, Eq a) => a -> a -> ImpCheckM ()
    checkEq t t' = assertEq t t' (pprint op)

class HasIType a where
  getIType :: a -> IType

instance HasIType ImpInstr where
  getIType = fromJust . impInstrType

instance HasIType IExpr where
  getIType x = case x of
    ILit val -> litType val
    IVar v   -> varAnn v

getMainFun :: HasCallStack => ImpModule -> ImpFunction
getMainFun (ImpModule fs) = fromJust $
  lookup impMainFunName [(name, f) | f@(ImpFunction (name:>_) _ _) <- fs]

impFunType :: ImpFunction -> IFunType
impFunType (ImpFunction (_:>ty) _ _) = ty

impBlockType :: ImpBlock -> [IType]
impBlockType (ImpBlock _ results) = map getIType results

impInstrType :: ImpInstr -> Maybe IType
impInstrType instr = case instr of
  IPrimOp op      -> Just $ impOpType op
  ICastOp t _     -> Just $ t
  Alloc a ty _    -> Just $ PtrType (AllocatedPtr, a, ty)
  Store _ _       -> Nothing
  Free _          -> Nothing
  IThrowError     -> Nothing

checkImpBinOp :: MonadError Err m => BinOp -> IType -> IType -> m IType
checkImpBinOp op x y = do
  retTy <- checkBinOp op (BaseTy x) (BaseTy y)
  case retTy of
    BaseTy bt -> return bt
    _         -> throw CompilerErr $ "Unexpected BinOp return type: " ++ pprint retTy

checkImpUnOp :: MonadError Err m => UnOp -> IType -> m IType
checkImpUnOp op x = do
  retTy <- checkUnOp op (BaseTy x)
  case retTy of
    BaseTy bt -> return bt
    _         -> throw CompilerErr $ "Unexpected UnOp return type: " ++ pprint retTy

-- TODO: reuse type rules in Type.hs
impOpType :: IPrimOp -> IType
impOpType pop = case pop of
  ScalarBinOp op x y -> ignoreExcept $ checkImpBinOp op (getIType x) (getIType y)
  ScalarUnOp  op x   -> ignoreExcept $ checkImpUnOp  op (getIType x)
  VectorBinOp op x y -> ignoreExcept $ checkImpBinOp op (getIType x) (getIType y)
  FFICall _ ty _     -> ty
  Select  _ x  _     -> getIType x
  VectorPack xs      -> Vector ty  where Scalar ty = getIType $ head xs
  VectorIndex x _    -> Scalar ty  where Vector ty = getIType x
  PtrLoad ref        -> ty  where PtrType (_, _, ty) = getIType ref
  PtrOffset ref _    -> PtrType (DerivedPtr, addr, ty)  where PtrType (_, addr, ty) = getIType ref
  _ -> unreachable
  where unreachable = error $ "Not allowed in Imp IR: " ++ pprint pop

withTypeEnv :: Env IType -> ImpCheckM a -> ImpCheckM a
withTypeEnv env m = local (\(prev, dev) -> (prev <> env, dev)) m

instance Pretty Dest where
  pretty dest = case dest of
    BaseTypeDest x -> "Base dest: " <> pretty x
    TabDest (Abs b dest) -> "\\for" <+> pretty b <+> "." <+> pretty dest
    DataConDest _ _ _ -> "data con dest"  -- TODO
    ConDest _         -> "con dest"  -- TODO
    ConstDest x -> pretty x

instance Semigroup ImpCatEnv where
  (ImpCatEnv a b c d e) <> (ImpCatEnv a' b' c' d' e') =
    ImpCatEnv (a<>a') (b<>b') (c<>c') (d<>d') (e<>e')

instance Monoid ImpCatEnv where
  mempty = ImpCatEnv mempty mempty mempty mempty mempty
  mappend = (<>)

pattern IIdxRepVal :: Int32 -> IExpr
pattern IIdxRepVal x = ILit (Int32Lit x)
