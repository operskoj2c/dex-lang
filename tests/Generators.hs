module Generators where

import Control.Monad
import Test.QuickCheck

import Record
import Env
import Syntax

arb :: Arbitrary a => Gen a
arb = arbitrary

smaller :: Int -> Gen a -> Gen a
smaller n m = scale (\size -> size `div` n) m  -- TODO: use ceil div instead?

oneOfFiltered :: [(Bool, Gen a)] -> Gen a
oneOfFiltered gens = oneof $ map snd $ filter fst gens

liftS2 :: (Arbitrary a, Arbitrary b) => (a -> b -> c) -> a -> b -> [c]
liftS2 f x y = [f x' y' | (x', y') <- shrink (x, y)]

liftS :: Arbitrary a => (a -> b) -> a -> [b]
liftS f x = map f (shrink x)

instance Arbitrary Name where
  arbitrary = liftM2 Name (elements ["x", "y"]) (elements [0, 1])
  shrink _ = []

instance Arbitrary Type where
  arbitrary = arbType 0
  shrink ty = case ty of
    BaseType _  -> [unitTy]
    TypeVar _   -> [unitTy]
    BoundTVar _ -> [unitTy]
    ArrType a b -> unitTy : a : b : liftS2 ArrType a b
    TabType a b -> unitTy : a : b : liftS2 TabType a b
    RecType r   -> liftS RecType r
    -- Forall kinds t ->
    -- Exists body ->
    -- IdxSetLit i ->

arbType :: Int -> Gen Type
arbType numBinders = do
  n <- getSize
  let nonLeaf = n>0
  oneOfFiltered
    [ (True, liftM BaseType arb)
    , (True, liftM TypeVar arbTypeName)
    , (nonLeaf, liftM2 ArrType (smaller 2 arb) (smaller 2 arb))
    , (nonLeaf, liftM2 TabType (smaller 2 arb) (smaller 2 arb))
    , (nonLeaf, liftM RecType arb)
    -- TODO: add explicit quantification to concrete syntax
    -- , (True, liftM (Forall [TyKind]) (arbType (numBinders + 1)))
    , (True, liftM Exists (arbType (numBinders + 1)))
    , (numBinders > 0, liftM BoundTVar (elements [0..numBinders-1]))]
    --     | IdxSetLit IdxSetVal

instance Arbitrary BaseType where
  arbitrary = elements [IntType, BoolType, RealType]  -- TODO: StrType
  shrink = undefined

instance Arbitrary a => Arbitrary (RecTree a) where
  arbitrary = frequency [ (2, liftM RecLeaf arb)
                        , (1, liftM RecTree arb) ]
  shrink (RecLeaf r) = liftS RecLeaf r


-- Note: empty tuples but no singletons
instance Arbitrary a => Arbitrary (Record a) where
  arbitrary = liftM Tup $ frequency
    [ (1, return [])
    , (2, sequence $ replicate 2 (smaller 2 arb)) ]
  shrink (Tup xs) = filter notSingleton $ liftS Tup xs
    where notSingleton ys = length ys /= 1
  -- TODO: generate named records too

instance Arbitrary b => Arbitrary (BinderP b) where
  arbitrary = liftM2 (:>) arb arb
  shrink (v:>ty) = liftS2 (:>) v ty

instance Arbitrary b => Arbitrary (TopDeclP b) where
  arbitrary = liftM TopDecl arb
  shrink topdecl = case topdecl of
    TopDecl decl -> liftS TopDecl decl
  -- TODO: commands

instance Arbitrary b => Arbitrary (DeclP b) where
  arbitrary = frequency
    [ (4, liftM2 Let arb arb)
    , (1, liftM2 TAlias arbTypeName arb)
    , (1, liftM3 Unpack arb arbTypeName arb)]
  shrink decl = case decl of
    Let p e     -> liftS2 Let p e
    TAlias v ty -> liftS2 TAlias v ty

instance Arbitrary b => Arbitrary (ExprP b) where
  arbitrary = oneof
    [ liftM Var arbitrary ]
  shrink _ = [] -- TODO: shrink
  -- TODO: the rest

instance Arbitrary Ann where
  arbitrary = oneof [return NoAnn, liftM Ann arb]
  shrink NoAnn = []
  shrink (Ann ann) = NoAnn : liftS Ann ann

arbTypeName :: Gen Name
arbTypeName = liftM2 Name (elements ["A", "B"]) (elements [0, 1])
