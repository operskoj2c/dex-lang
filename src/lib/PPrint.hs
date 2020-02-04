-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module PPrint (pprint, assertEq, ignoreExcept, printLitBlock) where

import Control.Monad.Except hiding (Except)
import GHC.Float
import Data.String
import Data.Text.Prettyprint.Doc.Render.Text
import Data.Text.Prettyprint.Doc
import Data.Text (unpack)
import Data.Foldable (toList)

import Env
import Syntax

pprint :: Pretty a => a -> String
pprint x = asStr $ pretty x

asStr :: Doc ann -> String
asStr doc = unpack $ renderStrict $ layoutPretty defaultLayoutOptions $ doc

p :: Pretty a => a -> Doc ann
p = pretty

instance Pretty Err where
  pretty (Err e _ s) = p e <> p s

instance Pretty ErrType where
  pretty e = case e of
    -- NoErr tags a chunk of output that was promoted into the Err ADT
    -- by appending Results.
    NoErr             -> ""
    ParseErr          -> "Parse error:"
    TypeErr           -> "Type error:"
    LinErr            -> "Linearity error: "
    UnboundVarErr     -> "Error: variable not in scope: "
    RepeatedVarErr    -> "Error: variable already defined: "
    NotImplementedErr -> "Not implemented:"
    CompilerErr       ->
      "Compiler bug!" <> line <>
      "Please report this at github.com/google-research/dex-lang/issues\n" <> line
    DataIOErr         -> "IO error: "
    MiscErr           -> "Error:"

instance Pretty Type where
  pretty t = prettyTyDepth 0 t

prettyTyDepth :: Int -> Type -> Doc ann
prettyTyDepth d ty = case ty of
  BaseType b  -> p b
  TypeVar v   -> p v
  BoundTVar n -> p (tvars d n)
  ArrType l a b -> parens $ recur a <+> arrStr l <+> recur b
  TabType a b -> parens $ recur a <> "=>" <> recur b
  RecType r   -> p $ fmap (asStr . recur) r
  TypeApp f xs -> p f <+> hsep (map p xs)
  Monad eff a -> "Monad" <+> hsep (map p (toList eff)) <+> p a
  Lens a b    -> "Lens" <+> p a <+> p b
  Exists body -> parens $ "E" <> p (tvars d (-1)) <> "." <> recurWith 1 body
  Forall []    t -> prettyTyDepth d t
  Forall kinds t -> header <+> prettyTyDepth (d + n) t
    where n = length kinds
          header = "A" <+> hsep binders <> "."
          boundvars :: [Name]
          boundvars = [tvars 0 i | i <- [-n..(-1)]]
          binders = map p $ zipWith (:>) boundvars kinds
  IdxSetLit i -> p i
  Mult l      -> p (show l)
  NoAnn       -> ""
  where recur = prettyTyDepth d
        recurWith n = prettyTyDepth (d + n)

instance Pretty ty => Pretty (EffectTypeP ty) where
  pretty (Effect r w s) = "[" <> p r <+> p w <+> p s <> "]"

tvars :: Int -> Int -> Name
tvars d i = fromString s
  where s = case d - i - 1 of i' | i' >= 0 -> [['a'..'z'] !! i']
                                 | otherwise -> "#ERR#"

instance Pretty BaseType where
  pretty t = case t of
    IntType  -> "Int"
    BoolType -> "Bool"
    RealType -> "Real"
    StrType  -> "Str"

printDouble :: Double -> Doc ann
printDouble x = p (double2Float x)

instance Pretty LitVal where
  pretty (IntLit x ) = p x
  pretty (RealLit x) = printDouble x
  pretty (StrLit x ) = p x
  pretty (BoolLit b) = if b then "True" else "False"

instance Pretty Expr where
  pretty (Decl decl body) = align $ p decl <> hardline <> p body
  pretty (CExpr expr) = p (PrimOpExpr expr)
  pretty (Atom atom) = p atom

instance Pretty FExpr where
  pretty expr = case expr of
    FVar (v:>ann) ts -> foldl (<+>) (p v) ["@" <> p t | t <- ts] <+> p ann
    FDecl decl body -> align $ p decl <> hardline <> p body
    FPrimExpr e -> p e
    SrcAnnot subexpr _ -> p subexpr
    Annot subexpr ty -> p subexpr <+> "::" <+> p ty

instance Pretty FDecl where
  -- TODO: special-case annotated leaf var (print type on own line)
  pretty (LetMono pat expr) = p pat <+> "=" <+> p expr
  pretty (LetPoly (v:>ty) (TLam _ body)) =
    p v <+> "::" <+> p ty <> line <>
    p v <+> "="  <+> p body
  pretty (FUnpack b tv expr) = p b <> "," <+> p tv <+> "= unpack" <+> p expr
  pretty (FRuleDef ann ty tlam) = "<TODO: rule def>"
  pretty (TyDef v bs ty) = "type" <+> p v <+> p bs <+> "=" <+> p ty

instance (Pretty ty, Pretty e, Pretty lam) => Pretty (PrimExpr ty e lam) where
  pretty (PrimOpExpr  op ) = p op
  pretty (PrimConExpr con) = p con

instance (Pretty ty, Pretty e, Pretty lam) => Pretty (PrimOp ty e lam) where
  pretty (App e1 e2) = p e1 <+> p e2
  pretty (For lam) = "build" <+> p lam
  pretty (TabCon _ xs) = list (map pretty xs)
  pretty (Cmp cmpOp _ x y) = "%cmp" <> p (show cmpOp) <+> p x <+> p y
  pretty (FFICall s _ _ xs) = "%%" <> p s <> tup xs
  pretty op = "%" <> p (nameToStr (PrimOpExpr blankOp))
                  <> (tupled $ (map (\t -> "@" <> p t) tys ++ map p xs ++ map p lams))
    where (blankOp, (tys, xs, lams)) = unzipExpr op

instance (Pretty ty, Pretty e, Pretty lam) => Pretty (PrimCon ty e lam) where
  pretty (Lit l)       = p l
  pretty (Lam _ lam)   = p lam
  pretty (TabGet e1 e2) = p e1 <> "." <> parens (p e2)
  pretty (RecGet e1 i ) = p e1 <> "#" <> parens (p i)
  pretty (RecCon r) = p r
  pretty (RecZip _ r) = "zip" <+> p r
  pretty (AtomicTabCon _ xs) = list (map pretty xs)
  pretty (IdxLit n i) = p i <> "@" <> p (IdxSetLit n)
  pretty con = p (nameToStr (PrimConExpr blankCon))
                  <> parens (p tys <+> p xs <+> p lams)
    where (blankCon, (tys, xs, lams)) = unzipExpr con

instance Pretty LamExpr where
  pretty (LamExpr b e) =
    parens $ align $ group $ "lam" <+> p b <+> "." <> line <> align (p e)

instance Pretty FLamExpr where
  pretty (FLamExpr pat e) =
    parens $ align $ group $ "lam" <+> p pat <+> "." <> line <> align (p e)

instance Pretty Kind where
  pretty (Kind cs) = case cs of
    []  -> ""
    [c] -> p c
    _   -> tupled $ map p cs

instance Pretty a => Pretty (VarP a) where
  pretty (v :> ann) =
    case asStr ann' of "" -> p v
                       _  -> p v <> "::" <> ann'
    where ann' = p ann

instance Pretty ClassName where
  pretty name = case name of
    Data   -> "Data"
    VSpace -> "VS"
    IdxSet -> "Ix"

instance Pretty Decl where
  pretty decl = case decl of
    Let    b bound -> p b <+> "=" <+> p (PrimOpExpr bound)
    Unpack b tv e  -> p b <> "," <+> p tv <+> "= unpack" <+> p e

instance Pretty TLamEnv where
  pretty _ = "<tlam>"

instance Pretty Atom where
  pretty atom = case atom of
    Var (x:>_)  -> p x
    PrimCon con -> p (PrimConExpr con)

arrStr :: Type -> Doc ann
arrStr (Mult Lin) = "--o"
arrStr _          = "->"

tup :: Pretty a => [a] -> Doc ann
tup [x] = p x
tup xs  = tupled $ map p xs

instance Pretty IExpr where
  pretty (ILit v) = p v
  pretty (IVar (v:>_)) = p v
  pretty (IGet expr idx) = p expr <> "." <> p idx
  pretty (IRef ref) = p ref

instance Pretty IType where
  pretty (IRefType (ty, shape)) = "Ptr (" <> p ty <> p shape <> ")"
  pretty (IValType b) = p b

instance Pretty ImpProg where
  pretty (ImpProg block) = vcat (map prettyStatement block)

prettyStatement :: (Maybe IVar, ImpInstr) -> Doc ann
prettyStatement (Nothing, instr) = p instr
prettyStatement (Just b , instr) = p b <+> "=" <+> p instr

instance Pretty ImpInstr where
  pretty (IPrimOp op)       = p op
  pretty (Load ref)         = "load"  <+> p ref
  pretty (Store dest val)   = "store" <+> p dest <+> p val
  pretty (Copy dest source) = "copy"  <+> p dest <+> p source
  pretty (Alloc ty)         = "alloc" <+> p ty
  pretty (Free (v:>_))      = "free"  <+> p v
  pretty (Loop i n block)   = "for"   <+> p i <+> "<" <+> p n <>
                               nest 4 (hardline <> p block)

instance Pretty a => Pretty (FlatValP a) where
  pretty (FlatVal ty refs) = "FlatVal (ty=" <> p ty <> ", refs= " <> p refs <> ")"

instance Pretty a => Pretty (ArrayP a) where
  pretty (Array shape ref) = p ref <> p shape

instance Pretty VecRef' where
  pretty (IntVecRef  ptr) = p $ show ptr
  pretty (RealVecRef ptr) = p $ show ptr
  pretty (BoolVecRef ptr) = p $ show ptr

instance Pretty Vec where
  pretty (IntVec  xs) = p xs
  pretty (RealVec xs) = p xs
  pretty (BoolVec xs) = p xs

instance Pretty a => Pretty (SetVal a) where
  pretty NotSet = ""
  pretty (Set a) = p a

instance (Pretty a, Pretty b) => Pretty (LorT a b) where
  pretty (L x) = "L" <+> p x
  pretty (T x) = "T" <+> p x

instance Pretty Output where
  pretty (ValOut Printed atom) = pretty atom
  pretty (ValOut _ _) = "<graphical output>"
  pretty (TextOut   s) = pretty s
  pretty (PassInfo name s) = p name <> ":" <> hardline <> p s <> hardline

instance Pretty SourceBlock where
  pretty block = pretty (sbText block)

instance Pretty Result where
  pretty (Result outs r) = vcat (map pretty outs) <> maybeErr
    where maybeErr = case r of Left err -> hardline <> p err
                               Right () -> mempty

instance Pretty FModule where
  pretty (FModule _ decls _) = vsep $ map p decls

instance Pretty Module where
  pretty (Module decls result) = vsep (map p decls) <> hardline <> p result

instance Pretty ImpModule where
  pretty (ImpModule vs prog result) =
    p vs <> hardline <> p prog <> hardline <> p result

instance (Pretty a, Pretty b) => Pretty (Either a b) where
  pretty (Left  x) = "Left"  <+> p x
  pretty (Right x) = "Right" <+> p x

printLitBlock :: SourceBlock -> Result -> String
printLitBlock block result = pprint block ++ resultStr
  where
    resultStr = unlines $ map addPrefix $ lines $ pprint result
    addPrefix :: String -> String
    addPrefix s = case s of "" -> ">"
                            _  -> "> " ++ s

assertEq :: (MonadError Err m, Pretty a, Eq a) => a -> a -> String -> m ()
assertEq x y s = if x == y then return ()
                           else throw CompilerErr msg
  where msg = s ++ ": " ++ pprint x ++ " != " ++ pprint y

ignoreExcept :: Except a -> a
ignoreExcept (Left e) = error $ pprint e
ignoreExcept (Right x) = x
