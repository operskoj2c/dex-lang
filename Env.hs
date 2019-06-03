{-# LANGUAGE OverloadedStrings #-}

module Env (Name (..), Tag, Env (..), envLookup, isin, envNames, envPairs,
            envDelete, envSubset, (!), (@>), BinderP (..), bind, bindFold,
            bindWith, binderAnn, binderVar, addAnnot,
            replaceAnnot, bindRecZip, lookupSubst) where

import Data.Traversable
import qualified Data.Map.Strict as M
import Control.Applicative (liftA)
import Data.Text.Prettyprint.Doc

import Record

infixr 7 :>

newtype Env a = Env (M.Map Name a)  deriving (Show, Eq, Ord)

data Name = Name Tag Int  deriving (Show, Ord, Eq)
type Tag = String
data BinderP a = (:>) Name a  deriving (Show, Eq, Ord)

envLookup :: Env a -> Name -> Maybe a
envLookup (Env m) v = M.lookup v m

envNames :: Env a -> [Name]
envNames (Env m) = M.keys m

envPairs :: Env a -> [(Name, a)]
envPairs (Env m) = M.toAscList m

lookupSubst :: Name -> Env Name -> Name
lookupSubst v (Env m) = M.findWithDefault v v m

envDelete :: Name -> Env a -> Env a
envDelete v (Env m) = Env (M.delete v m)

envSubset :: [Name] -> Env a -> Env a
envSubset vs (Env m) = Env $ M.intersection m (M.fromList [(v,()) | v <- vs])

isin :: Name -> Env a -> Bool
isin v env = case envLookup env v of Just _  -> True
                                     Nothing -> False

(!) :: Env a -> Name -> a
env ! v = case envLookup env v of
  Just x -> x
  Nothing -> error $ "Lookup of " ++ show v
                       ++ " in " ++ show (envNames env) ++ " failed"

infixr 7 @>

(@>) :: Name -> a -> Env a
k @> v = Env $ M.singleton k v

bind :: BinderP a -> Env a
bind (v :> x) = v @> x

bindWith :: BinderP a -> b -> Env (a, b)
bindWith b y = bind $ fmap (\x -> (x,y)) b

bindFold :: Foldable f => f (BinderP a) -> Env a
bindFold bs = foldMap bind bs

bindRecZip :: RecTreeZip t => RecTree (BinderP a) -> t -> Env (a, t)
bindRecZip bs t = foldMap (uncurry bindWith) (recTreeZip bs t)

binderAnn :: BinderP a -> a
binderAnn (_ :> x) = x

binderVar :: BinderP a -> Name
binderVar (v :> _) = v

addAnnot :: BinderP a -> b -> BinderP (a, b)
addAnnot b y = fmap (\x -> (x, y)) b

replaceAnnot :: BinderP a -> b -> BinderP b
replaceAnnot b y = fmap (const y) b

instance Functor Env where
  fmap = fmapDefault

instance Foldable Env where
  foldMap = foldMapDefault

instance Traversable Env where
  traverse f (Env m) = liftA Env (traverse f m)


-- Note: Env is right-biased, so that we extend envs on the right
instance Semigroup (Env a) where
  Env m <> Env m' = Env (m' <> m)

instance Monoid (Env a) where
  mempty = Env mempty
  mappend = (<>)

instance Pretty a => Pretty (Env a) where
  pretty (Env m) = pretty (M.toAscList m)

instance Pretty a => Pretty (BinderP a) where
  pretty (v :> x) = pretty v   <> "::" <> pretty x

instance Functor BinderP where
  fmap = fmapDefault

instance Foldable BinderP where
  foldMap = foldMapDefault

instance Traversable BinderP where
  traverse f (v :> x) = fmap (v:>) (f x)

-- TODO: this needs to be injective but it's currently not
-- (needs to figure out acceptable tag strings)
instance Pretty Name where
  pretty (Name tag n) = pretty tag <> suffix
            where suffix = case n of 0 -> ""
                                     _ -> "_" <> pretty n
