-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE PatternSynonyms #-}

module Syntax (
    Type, Kind, BaseType (..), Effect, EffectiveType,
    ClassName (..), TyQual (..), SrcPos, Pat, Var, Block (..), Decl (..),
    Expr (..), Atom (..), LamExpr (..), ArrowHead (..), PrimTC (..),
    PrimExpr (..), PrimCon (..), LitVal (..), PrimEffect (..), PrimOp (..),
    PrimHof (..),
    ScalarBinOp (..), ScalarUnOp (..), CmpOp (..), SourceBlock (..),
    ReachedEOF, SourceBlock' (..), TypeEnv, SubstEnv, Scope, RuleEnv,
    CmdName (..), Val, TopInfEnv, TopSimpEnv, TopEnv (..), Op, Con, Hof, TC,
    Module (..), Module, ImpFunction (..),
    ImpProg (..), ImpStatement, ImpInstr (..), IExpr (..), IVal, IPrimOp,
    IVar, IType (..), ArrayType, IArrayType, SetVal (..), MonMap (..), LitProg,
    SrcCtx, Result (..), Output (..), OutFormat (..), DataFormat (..),
    Err (..), ErrType (..), Except, throw, throwIf, modifyErr, addContext,
    addSrcContext, catchIOExcept, liftEitherIO, (-->), (--@), (==>),
    sourceBlockBoundVars, PassName (..), parsePassName,
    freeVars, freeUVars, HasVars, strToName, nameToStr, showPrimName,
    noEffect, isPure, EffectName (..), EffectRow, Vars,
    monMapSingle, monMapLookup, PiType (..),
    newEnv, Direction (..), ArrayRef, Array, Limit (..),
    UExpr (..), UExpr' (..), UType, UBinder, UVar,
    Pat, UModule (..), UDecl (..), ULamExpr (..), UPiType (..),
    subst, deShadow, scopelessSubst, piArgType, applyPi, freshSkolemVar,
    pattern IntVal, pattern UnitTy, pattern PairTy, pattern TupTy,
    pattern FixedIntRange, pattern RefTy, pattern BoolTy, pattern IntTy, pattern RealTy,
    pattern RecTy, pattern SumTy, pattern ArrayTy, pattern BaseTy, pattern UnitVal,
    pattern PairVal, pattern TupVal, pattern RecVal, pattern SumVal,
    pattern RealVal, pattern BoolVal, pattern TyKind, pattern TabGet, pattern TabTy)
  where

import qualified Data.Map.Strict as M
import Control.Applicative
import Control.Exception hiding (throw)
import Control.Monad.Fail
import Control.Monad.Identity
import Control.Monad.Writer
import Control.Monad.Except hiding (Except)
import Control.Monad.Reader
import qualified Data.Vector.Unboxed as V
import Data.Bifunctor
import Data.Bifoldable
import Data.Bitraversable
import Data.Foldable (fold)
import Data.Tuple (swap)
import Data.Maybe (fromJust)
import Control.Applicative (liftA3)
import GHC.Generics

import Cat
import Record
import Env
import Array

-- === core IR ===

data Atom = Var Var
          | Lam   ArrowHead LamExpr
          | Arrow ArrowHead PiType
          -- (Maybe Type) for the optional row tail variable
          | Effect (EffectRow Type) (Maybe Type)
          | Con Con
          | TC  TC
            deriving (Show, Eq, Generic)

data Expr = App ArrowHead Atom Atom
          | For Direction LamExpr  -- TODO: put in hofs?
          | Atom Atom
          | Op  Op
          | Hof Hof
            deriving (Show, Eq, Generic)

data Block = Block [Decl] Expr Effect
             deriving (Show, Eq, Generic)

type Var  = VarP Type
data Decl = Let Var Expr  deriving (Show, Eq, Generic)
data LamExpr = LamExpr Var Block  deriving (Show, Eq, Generic)
data PiType = Pi Var EffectiveType  deriving (Show)

data ArrowHead = PlainArrow
               | ImplicitArrow
               | TabArrow
               | LinArrow
                 deriving (Show, Eq, Generic)

type Val  = Atom
type Type = Atom
type Kind = Type

type TC  = PrimTC  Atom
type Con = PrimCon Atom
type Op  = PrimOp  Atom
type Hof = PrimHof Atom LamExpr

type TypeEnv  = Env Type
type SrcPos = (Int, Int)

data TopEnv = TopEnv TopInfEnv TopSimpEnv RuleEnv
              deriving (Show, Eq, Generic)

type TopInfEnv  = (TypeEnv, Env Type)
type TopSimpEnv = SubstEnv
type RuleEnv    = Env Atom

data Module = Module (Maybe BlockId) [Var] [Var] Block  deriving (Show, Eq)

-- === effects ===

-- This represents a row like {Writer (x :: Ref t), Reader (y :: Ref t')}
-- as the following map: {x: (Writer, t), y: (Reader, t')}.
type EffectRow a = Env (EffectName, a)
data EffectName = Reader | Writer | State  deriving (Eq, Show, Generic)

type Effect = Type
type EffectiveType = (Effect, Type)

noEffect :: Effect
noEffect = Effect mempty Nothing

isPure :: Effect -> Bool
isPure (Effect eff Nothing) | eff == mempty = True
isPure _ = False

-- === front-end language AST ===

data UExpr = UPos SrcPos UExpr'  deriving (Show, Eq, Generic)

data UExpr' = UVar UVar
            | ULam   ArrowHead ULamExpr
            | UApp   ArrowHead UExpr UExpr
            | UArrow ArrowHead UPiType
            | UFor Direction ULamExpr
            | UDecl UDecl UExpr
            | UPrimExpr (PrimExpr Name Name)
            | UAnnot UExpr UType
              deriving (Show, Eq, Generic)

data UDecl = ULet Pat UExpr         deriving (Show, Eq, Generic)
data ULamExpr = ULamExpr Pat UExpr  deriving (Show, Eq, Generic)
data UPiType  = UPi UPiBinder UType  deriving (Show, Eq, Generic)

type UType = UExpr
type UVar    = VarP ()
type UBinder = VarP (Maybe UType)
type UPiBinder = VarP UType
type Pat = RecTree UBinder

data UModule = UModule [Name] [Name] [UDecl]  deriving (Show, Eq)

-- === primitive constructors and operators ===

data PrimExpr e lam =
        TCExpr  (PrimTC  e)
      | ConExpr (PrimCon e)
      | OpExpr  (PrimOp  e)
      | HofExpr (PrimHof e lam)
        deriving (Show, Eq, Generic)

data PrimTC e =
        BaseType BaseType
      | IntRange e e
      | IndexRange e (Limit e) (Limit e)
      | ArrayType ArrayType
      | RecType (Record e)
      | SumType (e, e)
      | RefType e
      | TypeKind
      | EffectKind
        deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data PrimCon e =
        Lit LitVal
      | ArrayLit Array
      | AnyValue e        -- Produces an arbitrary value of a given type
      | SumCon e e e      -- (bool constructor tag (True is Left), left value, right value)
      | RecCon (Record e)
      | AsIdx e e         -- Construct an index from its ordinal index (zero-based int)
      | AFor e e
      | AGet e
      | Todo e
        deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data PrimOp e =
        RecGet e RecField
      | SumGet e Bool
      | SumTag e
      | ArrayGep e e
      | LoadScalar e
      | TabCon e e [e]               -- index set, element type, elements
      | ScalarBinOp ScalarBinOp e e
      | ScalarUnOp ScalarUnOp e
      | Select e e e                 -- predicate, val-if-true, val-if-false
      | PrimEffect e (PrimEffect e)
      | FFICall String [BaseType] BaseType [e]
      | Inject e
      -- Typeclass operations
      -- Eq and Ord (should get eliminated during simplification)
      | Cmp CmpOp e e e  -- type, left, right
      -- Idx (survives simplification, because we allow it to be backend-dependent)
      | IntAsIndex e e   -- index set, ordinal index
      | IndexAsInt e
      | IdxSetSize e
        deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data PrimHof e lam =
        SumCase e lam lam
      | RunReader e  lam
      | RunWriter    lam
      | RunState  e  lam
      | Linearize lam
      | Transpose lam
        deriving (Show, Eq, Generic)

data PrimEffect e = MAsk | MTell e | MGet | MPut e
    deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data ScalarBinOp = IAdd | ISub | IMul | IDiv | ICmp CmpOp
                 | FAdd | FSub | FMul | FDiv | FCmp CmpOp | Pow
                 | And | Or | Rem
                   deriving (Show, Eq, Generic)

data ScalarUnOp = Not | FNeg | IntToReal | BoolToInt | UnsafeIntToBool
                  deriving (Show, Eq, Generic)

data CmpOp = Less | Greater | Equal | LessEqual | GreaterEqual
             deriving (Show, Eq, Generic)

data Direction = Fwd | Rev  deriving (Show, Eq, Generic)

data Limit a = InclusiveLim a
             | ExclusiveLim a
             | Unlimited
               deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data ClassName = Data | VSpace | IdxSet | Eq | Ord deriving (Show, Eq, Generic)

data TyQual = TyQual Var ClassName  deriving (Show, Eq, Generic)

type PrimName = PrimExpr () ()

strToName :: String -> Maybe PrimName
strToName s = M.lookup s builtinNames

nameToStr :: PrimName -> String
nameToStr prim = case lookup prim $ map swap $ M.toList builtinNames of
  Just s  -> s
  Nothing -> show prim

showPrimName :: PrimExpr e lam -> String
showPrimName prim = nameToStr $ bimap (const ()) (const ()) prim

-- === top-level constructs ===

data SourceBlock = SourceBlock
  { sbLine     :: Int
  , sbOffset   :: Int
  , sbText     :: String
  , sbContents :: SourceBlock'
  , sbId       :: Maybe BlockId }  deriving (Show)

type BlockId = Int
type ReachedEOF = Bool
data SourceBlock' = RunModule UModule
                  | Command CmdName (Name, UModule)
                  | GetNameType Var
                  | IncludeSourceFile String
                  | LoadData Pat DataFormat String
                  | ProseBlock String
                  | CommentLine
                  | EmptyLines
                  | UnParseable ReachedEOF String
                    deriving (Show, Eq, Generic)

data CmdName = GetType | ShowPasses | ShowPass PassName
             | TimeIt | EvalExpr OutFormat | Dump DataFormat String
                deriving  (Show, Eq, Generic)

-- === imperative IR ===

-- TODO: add args
data ImpFunction = ImpFunction [IVar] [IVar] ImpProg  -- destinations first
                   deriving (Show, Eq)
newtype ImpProg = ImpProg [ImpStatement]
                  deriving (Show, Eq, Generic, Semigroup, Monoid)
type ImpStatement = (Maybe IVar, ImpInstr)

data ImpInstr = Load  IExpr
              | Store IExpr IExpr  -- destination first
              | Copy  IExpr IExpr  -- destination first
              | Alloc IArrayType
              | Free IVar
              | IGet IExpr Index
              | Loop Direction IVar Size ImpProg
              | IPrimOp IPrimOp
                deriving (Show, Eq)

data IExpr = ILit LitVal
           | IVar IVar
             deriving (Show, Eq)

type IPrimOp = PrimOp IExpr
type IVal = IExpr  -- only ILit and IRef constructors
type IVar = VarP IType
data IType = IValType BaseType
           | IRefType IArrayType
              deriving (Show, Eq)

type IArrayType = (BaseType, [Size])

type Size  = IExpr
type Index = IExpr

-- === some handy monoids ===

data SetVal a = Set a | NotSet
newtype MonMap k v = MonMap (M.Map k v)  deriving (Show, Eq)

instance Semigroup (SetVal a) where
  x <> NotSet = x
  _ <> Set x  = Set x

instance Monoid (SetVal a) where
  mempty = NotSet

instance (Ord k, Semigroup v) => Semigroup (MonMap k v) where
  MonMap m <> MonMap m' = MonMap $ M.unionWith (<>) m m'

instance (Ord k, Semigroup v) => Monoid (MonMap k v) where
  mempty = MonMap mempty

monMapSingle :: k -> v -> MonMap k v
monMapSingle k v = MonMap (M.singleton k v)

monMapLookup :: (Monoid v, Ord k) => MonMap k v -> k -> v
monMapLookup (MonMap m) k = case M.lookup k m of Nothing -> mempty
                                                 Just v  -> v

-- === passes ===

data PassName = Parse | TypePass | NormPass | SimpPass | ImpPass | JitPass
              | Flops | LLVMOpt | AsmPass | JAXPass | JAXSimpPass | LLVMEval
              | JaxprAndHLO
                deriving (Ord, Eq, Bounded, Enum)

passNameMap :: M.Map String PassName
passNameMap = buildNameMap

parsePassName :: String -> Maybe PassName
parsePassName s = M.lookup s passNameMap

instance Show PassName where
  show p = case p of
    Parse    -> "parse" ; TypePass -> "typed"   ; NormPass -> "norm"
    SimpPass -> "simp"  ; ImpPass  -> "imp"     ; JitPass  -> "llvm"
    Flops    -> "flops" ; LLVMOpt  -> "llvmopt" ; AsmPass  -> "asm"
    JAXPass  -> "jax"   ; JAXSimpPass -> "jsimp";
    LLVMEval -> "llvmeval" ; JaxprAndHLO -> "jaxprhlo";

-- TODO: consider using this for builtins too
buildNameMap :: (Show a, Enum a, Bounded a) => M.Map String a
buildNameMap = M.fromList [(show x, x) | x <- [minBound..maxBound]]

-- === outputs ===

type LitProg = [(SourceBlock, Result)]
type SrcCtx = Maybe SrcPos
data Result = Result [Output] (Except ())  deriving (Show, Eq)

data Output = TextOut String
            | HeatmapOut Int Int (V.Vector Double)
            | ScatterOut (V.Vector Double) (V.Vector Double)
            | PassInfo PassName String
            | MiscLog String
              deriving (Show, Eq, Generic)

data OutFormat = Printed | Heatmap | Scatter   deriving (Show, Eq, Generic)
data DataFormat = DexObject | DexBinaryObject  deriving (Show, Eq, Generic)

data Err = Err ErrType SrcCtx String  deriving (Show, Eq)
instance Exception Err

data ErrType = NoErr
             | ParseErr
             | TypeErr
             | KindErr
             | LinErr
             | UnboundVarErr
             | RepeatedVarErr
             | CompilerErr
             | NotImplementedErr
             | DataIOErr
             | MiscErr
  deriving (Show, Eq)

type Except = Either Err

throw :: MonadError Err m => ErrType -> String -> m a
throw e s = throwError $ Err e Nothing s

throwIf :: MonadError Err m => Bool -> ErrType -> String -> m ()
throwIf True  e s = throw e s
throwIf False _ _ = return ()

modifyErr :: MonadError e m => m a -> (e -> e) -> m a
modifyErr m f = catchError m $ \e -> throwError (f e)

addContext :: MonadError Err m => String -> m a -> m a
addContext s m = modifyErr m $ \(Err e p s') -> Err e p (s' ++ s)

addSrcContext :: MonadError Err m => SrcCtx -> m a -> m a
addSrcContext ctx m = modifyErr m updateErr
  where
    updateErr :: Err -> Err
    updateErr (Err e ctx' s) = case ctx' of Nothing -> Err e ctx  s
                                            Just _  -> Err e ctx' s

catchIOExcept :: (MonadIO m , MonadError Err m) => IO a -> m a
catchIOExcept m = (liftIO >=> liftEither) $ (liftM Right m) `catches`
  [ Handler $ \(e::Err)           -> return $ Left e
  , Handler $ \(e::IOError)       -> return $ Left $ Err DataIOErr   Nothing $ show e
  , Handler $ \(e::SomeException) -> return $ Left $ Err CompilerErr Nothing $ show e
  ]

liftEitherIO :: (Exception e, MonadIO m) => Either e a -> m a
liftEitherIO (Left err) = liftIO $ throwIO err
liftEitherIO (Right x ) = return x

instance MonadFail (Either Err) where
  fail s = Left $ Err CompilerErr Nothing s

-- === UExpr free variables ===

type UVars = Env ()

class HasUVars a where
  freeUVars :: a -> UVars

instance HasUVars UExpr where
  freeUVars (UPos _ e) = freeUVars e

instance HasUVars UExpr' where
  freeUVars expr = case expr of
    UVar v -> v@>()
    ULam _ lam -> freeUVars lam
    UFor _ lam -> freeUVars lam
    UApp _ f x -> freeUVars f <> freeUVars x
    UArrow _ piTy -> freeUVars piTy
    UDecl decl@(ULet p _) body ->
      freeUVars decl <> (freeUVars body `envDiff` boundVars)
      where boundVars = foldMap (@>()) p
    UAnnot expr ann -> freeUVars expr <> freeUVars ann
    _ -> mempty

instance HasUVars UDecl where
  freeUVars (ULet p expr) = foldMap uBinderFreeVars p <> freeUVars expr

instance HasUVars ULamExpr where
  freeUVars (ULamExpr p expr) =
    foldMap uBinderFreeVars p <> (freeUVars expr `envDiff` foldMap (@>()) p)

instance HasUVars UPiType where
  freeUVars (UPi v@(_:>ann) b) = freeUVars ann <> (freeUVars b `envDiff` (v@>()))

instance HasUVars SourceBlock where
  freeUVars block = case sbContents block of
    RunModule (   UModule vs _ _) -> foldMap nameAsEnv vs
    Command _ (_, UModule vs _ _) -> foldMap nameAsEnv vs
    GetNameType v                 -> v @> ()
    _ -> mempty

uBinderFreeVars :: UBinder -> UVars
uBinderFreeVars (_:>ann) = foldMap freeUVars ann

sourceBlockBoundVars :: SourceBlock -> UVars
sourceBlockBoundVars block = case sbContents block of
  RunModule (UModule _ vs _) -> foldMap nameAsEnv vs
  LoadData p _ _             -> foldMap (@>()) p
  _                          -> mempty

nameAsEnv :: Name -> UVars
nameAsEnv v = (v:>())@>()

-- === Expr free variables and substitutions ===

type Vars = TypeEnv
type SubstEnv = Env Atom
type Scope    = Env (Maybe Expr)
type ScopedSubstEnv = (SubstEnv, Scope)

scopelessSubst :: HasVars a => SubstEnv -> a -> a
scopelessSubst env x = subst (env, scope) x
  where scope = fmap (const Nothing) $
          foldMap freeVars env <> (freeVars x `envDiff` env)

class HasVars a where
  freeVars :: a -> Vars
  subst :: ScopedSubstEnv -> a -> a

instance HasVars PiType where
  freeVars (Pi b@(_:>ty) body) = freeVars ty <> (freeVars body `envDiff` (b@>()))
  subst env (Pi (v:>ty) body) = Pi b body'
    where (b, env') = refreshBinder env (v:> subst env ty)
          body' = subst (env <> env') body

instance Eq PiType where
  Pi (NoName:>a) b == Pi (NoName:>a') b' = a == a' && b == b'
  piTy@(Pi (_:>a) _) == piTy'@(Pi (_:>a') _) =
    a == a' && applyPi piTy v == applyPi piTy' v
    where v = Var $ freshSkolemVar (piTy, piTy') a

freshSkolemVar :: HasVars a => a -> Type -> Var
freshSkolemVar x ty = rename (rawName Skolem "x" :> ty) (freeVars x)

-- NOTE: We don't have an instance for VarP, because it's used to represent
--       both binders and regular variables, but each requires different treatment
freeBinderTypeVars :: Var -> Vars
freeBinderTypeVars (_ :> t) = freeVars t

applyPi :: PiType -> Atom -> EffectiveType
applyPi (Pi v body) x = scopelessSubst (v@>x) body

piArgType :: PiType -> Type
piArgType (Pi (_:>ty) _) = ty

isDependentType :: PiType -> Bool
isDependentType (Pi v body) = v `isin` freeVars body

varFreeVars :: Var -> Vars
varFreeVars v@(_ :> t) = bind v <> freeVars t

bind :: VarP a -> Env a
bind v@(_:>ty) = v @> ty

newEnv :: [VarP ann] -> [a] -> Env a
newEnv vs xs = fold $ zipWith (@>) vs xs

instance HasVars Atom where
  freeVars atom = case atom of
    Var v      -> varFreeVars v
    Lam _  lam -> freeVars lam
    Arrow _ pi -> freeVars pi
    Effect row tailVar ->  foldMap (varFreeVars . \(v, (_,t)) -> v:>t) (envPairs row)
                        <> foldMap freeVars tailVar
    Con con -> foldMap freeVars con
    TC  tc  -> foldMap freeVars tc

  subst env@(sub, _) atom = case atom of
    Var v -> substVar env v
    Lam   h lam  -> Lam   h $ subst env lam
    Arrow h piTy -> Arrow h $ subst env piTy
    Effect _ _ -> noEffect
    TC  tc  -> TC  $ fmap (subst env) tc
    Con con -> Con $ fmap (subst env) con

substVar :: (SubstEnv, Scope) -> Var -> Atom
substVar env@(sub, scope) v = case envLookup sub v of
  Nothing -> Var $ fmap (subst env) v
  Just x' -> deShadow x' scope

deShadow :: HasVars a => a -> Scope -> a
deShadow x scope = subst (mempty, scope) x

instance HasVars Expr where
  freeVars expr = case expr of
    App _ f x -> freeVars f <> freeVars x
    For _ lam -> freeVars lam
    Atom atom -> freeVars atom
    Op  e     -> foldMap freeVars e
    Hof e     -> bifoldMap freeVars freeVars e

  subst env expr = case expr of
    App h f x   -> App h (subst env f) (subst env x)
    For dir lam -> For dir $ subst env lam
    Atom x      -> Atom $ subst env x
    Op  e       -> Op  $ fmap (subst env) e
    Hof e       -> Hof $ bimap (subst env) (subst env) e

instance HasVars Decl where
  freeVars (Let bs expr) = foldMap freeVars bs <> freeVars expr
  subst env (Let (v:>ty) bound) = Let (v:> subst env ty) (subst env bound)

instance HasVars Block where
  -- TODO: effects
  freeVars (Block [] result _) = freeVars result
  freeVars (Block (decl@(Let b _):decls) result eff) =
    freeVars decl <> (freeVars body `envDiff` (b@>()))
    where body = Block decls result eff

  -- TODO: effects
  subst env (Block decls result eff) = do
    let (decls', env') = catMap substDecl env decls
    let result' = subst (env <> env') result
    Block decls' result' eff

instance HasVars LamExpr where
  freeVars (LamExpr b body) =
    freeBinderTypeVars b <> (freeVars body `envDiff` (b@>()))

  subst env (LamExpr (v:>ty) body) = LamExpr b body'
    where (b, env') = refreshBinder env (v:> subst env ty)
          body' = subst (env <> env') body

substDecl :: ScopedSubstEnv -> Decl -> (Decl, ScopedSubstEnv)
substDecl env (Let (v:>ty) bound) = (Let b (subst env bound), env')
  where (b, env') = refreshBinder env (v:> subst env ty)

refreshBinder :: ScopedSubstEnv -> Var -> (Var, ScopedSubstEnv)
refreshBinder (_, scope) b = (b', env')
  where b' = rename b scope
        env' = (b@>Var b', b'@>Nothing)

instance HasVars TopEnv where
  freeVars (TopEnv e1 e2 e3) = freeVars e1 <> freeVars e2 <> freeVars e3

instance HasVars () where
  freeVars () = mempty
  subst _ () = ()

instance (HasVars a, HasVars b) => HasVars (a, b) where
  freeVars (x, y) = freeVars x <> freeVars y
  subst env (x, y) = (subst env x, subst env y)

instance (HasVars a, HasVars b) => HasVars (Either a b)where
  freeVars (Left  x) = freeVars x
  freeVars (Right x) = freeVars x

instance HasVars a => HasVars (Env a) where
  freeVars x = foldMap freeVars x
  subst env x = fmap (subst env) x

instance HasVars a => HasVars (RecTree a) where
  freeVars x = foldMap freeVars x
  subst env x = fmap (subst env) x

instance HasVars a => HasVars [a] where
  freeVars x = foldMap freeVars x
  subst env x = fmap (subst env) x

instance RecTreeZip Type where
  recTreeZip (RecTree r) (TC (RecType r')) = RecTree $ recZipWith recTreeZip r r'
  recTreeZip (RecLeaf x) x' = RecLeaf (x, x')
  recTreeZip (RecTree _) _ = error "Bad zip"

instance Semigroup TopEnv where
  TopEnv e1 e2 e3 <> TopEnv e1' e2' e3'=
    TopEnv (e1 <> e1') (e2 <> e2') (e3 <> e3')

instance Monoid TopEnv where
  mempty = TopEnv mempty mempty mempty

instance Eq SourceBlock where
  x == y = sbText x == sbText y

instance Ord SourceBlock where
  compare x y = compare (sbText x) (sbText y)

-- === Synonyms ===

infixr 1 -->
infixr 1 --@
infixr 2 ==>

(-->) :: Type -> Type -> Type
a --> b = Arrow PlainArrow $ Pi (NoName:>a) (noEffect, b)

(--@) :: Type -> Type -> Type
a --@ b = Arrow LinArrow $ Pi (NoName:>a) (noEffect, b)

(==>) :: Type -> Type -> Type
a ==> b = Arrow TabArrow $ Pi (NoName:>a) (noEffect, b)

pattern IntVal :: Int -> Atom
pattern IntVal x = Con (Lit (IntLit x))

pattern RealVal :: Double -> Atom
pattern RealVal x = Con (Lit (RealLit x))

pattern BoolVal :: Bool -> Atom
pattern BoolVal x = Con (Lit (BoolLit x))

pattern RecVal :: Record Atom -> Atom
pattern RecVal r = Con (RecCon r)

pattern SumVal :: Atom -> Atom -> Atom -> Atom
pattern SumVal t l r = Con (SumCon t l r)

pattern TupVal :: [Atom] -> Atom
pattern TupVal xs = RecVal (Tup xs)

pattern PairVal :: Atom -> Atom -> Atom
pattern PairVal x y = TupVal [x, y]

pattern PairTy :: Type -> Type -> Type
pattern PairTy x y = TC (RecType (Tup [x, y]))

pattern TupTy :: [Type] -> Type
pattern TupTy xs = TC (RecType (Tup xs))

pattern UnitVal :: Atom
pattern UnitVal = TupVal []

pattern UnitTy :: Type
pattern UnitTy = TupTy []

pattern ArrayTy :: [Int] -> BaseType -> Type
pattern ArrayTy shape b = TC (ArrayType (shape, b))

pattern BaseTy :: BaseType -> Type
pattern BaseTy b = TC (BaseType b)

pattern RecTy :: Record Type -> Type
pattern RecTy a = TC (RecType a)

pattern SumTy :: Type -> Type -> Type
pattern SumTy l r = TC (SumType (l, r))

pattern RefTy :: Type -> Type
pattern RefTy a = TC (RefType a)

pattern IntTy :: Type
pattern IntTy = TC (BaseType IntType)

pattern BoolTy :: Type
pattern BoolTy = TC (BaseType BoolType)

pattern RealTy :: Type
pattern RealTy = TC (BaseType RealType)

pattern TyKind :: Kind
pattern TyKind = TC TypeKind

pattern FixedIntRange :: Int -> Int -> Type
pattern FixedIntRange low high = TC (IntRange (IntVal low) (IntVal high))

pattern TabGet :: Atom -> Atom -> Expr
pattern TabGet xs i = App TabArrow xs i

-- we want to pattern-match against the empty effect too, but our current
-- representation doesn't allow that
pattern TabTy :: Atom -> Atom -> Effect -> Type
pattern TabTy xs i eff = Arrow TabArrow (Pi (NoName:>xs) (eff, i))

-- TODO: Enable once https://gitlab.haskell.org//ghc/ghc/issues/13363 is fixed...
-- {-# COMPLETE TypeVar, ArrowType, TabTy, Forall, TypeAlias, Effect, NoAnn, TC #-}

-- TODO: Can we derive these generically? Or use Show/Read?
--       (These prelude-only names don't have to be pretty.)
builtinNames :: M.Map String PrimName
builtinNames = M.fromList
  [ ("iadd", binOp IAdd), ("isub", binOp ISub)
  , ("imul", binOp IMul), ("fdiv", binOp FDiv)
  , ("fadd", binOp FAdd), ("fsub", binOp FSub)
  , ("fmul", binOp FMul), ("idiv", binOp IDiv)
  , ("pow" , binOp Pow ), ("rem" , binOp Rem )
  , ("and" , binOp And ), ("or"  , binOp Or  ), ("not" , unOp  Not )
  , ("fneg", unOp  FNeg)
  , ("inttoreal", unOp IntToReal)
  , ("booltoint", unOp BoolToInt)
  , ("asint"       , OpExpr $ IndexAsInt ())
  , ("idxSetSize"  , OpExpr $ IdxSetSize ())
  , ("asidx"       , OpExpr $ IntAsIndex () ())
  , ("select"      , OpExpr $ Select () () ())
  , ("todo"       , ConExpr $ Todo ())
  , ("ask"        , OpExpr $ PrimEffect () $ MAsk)
  , ("tell"       , OpExpr $ PrimEffect () $ MTell ())
  , ("get"        , OpExpr $ PrimEffect () $ MGet)
  , ("put"        , OpExpr $ PrimEffect () $ MPut  ())
  , ("inject"     , OpExpr $ Inject ())
  , ("linearize"       , HofExpr $ Linearize ())
  , ("linearTranspose" , HofExpr $ Transpose ())
  , ("runReader"       , HofExpr $ RunReader () ())
  , ("runWriter"       , HofExpr $ RunWriter    ())
  , ("runState"        , HofExpr $ RunState  () ())
  , ("Int"     , TCExpr $ BaseType IntType)
  , ("Real"    , TCExpr $ BaseType RealType)
  , ("Bool"    , TCExpr $ BaseType BoolType)
  , ("TyKind"  , TCExpr $ TypeKind)
  , ("IntRange", TCExpr $ IntRange () ())
  ]
  where
    binOp op = OpExpr $ ScalarBinOp op () ()
    unOp  op = OpExpr $ ScalarUnOp  op ()

instance Bifunctor  PrimHof where bimap     = bimapDefault
instance Bifoldable PrimHof where bifoldMap = bifoldMapDefault

instance Bitraversable PrimHof  where
  bitraverse f g hof = case hof of
    SumCase e lam1 lam2 -> SumCase <$> f e <*> g lam1 <*> g lam2
    RunReader e  lam -> RunReader <$> f e <*> g lam
    RunWriter    lam -> RunWriter <$>         g lam
    RunState  e  lam -> RunState  <$> f e <*> g lam
    Linearize lam -> Linearize <$> g lam
    Transpose lam -> Transpose <$> g lam

instance Bifunctor  PrimExpr where bimap     = bimapDefault
instance Bifoldable PrimExpr where bifoldMap = bifoldMapDefault

instance Bitraversable PrimExpr where
  bitraverse f g expr = case expr of
    TCExpr  e -> TCExpr  <$> traverse f e
    ConExpr e -> ConExpr <$> traverse f e
    OpExpr  e -> OpExpr  <$> traverse f e
    HofExpr e -> HofExpr <$> bitraverse f g e
