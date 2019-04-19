module Parser (parseProg) where

import Util
import Record
import ParseUtil
import Syntax
import Fresh
import Env

import Control.Monad
import Control.Monad.Combinators.Expr
import Control.Monad.Identity
import Control.Monad.Reader (ReaderT, runReaderT, local, ask, asks)
import Control.Monad.State (StateT, runState, modify)
import Text.Megaparsec
import qualified Text.Megaparsec.Char.Lexer as L
import Test.HUnit
import Data.Foldable (toList)

type Prog = [([String], UDecl)]

data LocalDecl = AssignDecl UPat UExpr
               | UnpackDecl Var UExpr

parseProg :: String -> Except Prog
parseProg = parseit prog

parseit :: Parser a -> String -> Except a
parseit p s = case parse (p <* eof) "" s of
                Left e -> throw ParseErr (errorBundlePretty e)
                Right x -> return x

prog :: Parser Prog
prog = emptyLines >> many (topDecl <*emptyLines)

topDecl :: Parser ([String], UDecl)
topDecl = do
  (instr, source) <- captureSource topDeclInstr
  return ([source], instr)

topDeclInstr :: Parser UDecl
topDeclInstr =   explicitCommand
             -- <|> typedAssignment
             <|> liftM (uncurry UTopUnpack) tryUnpackDecl
             <|> liftM (uncurry UTopLet   ) tryAssignDecl
             <|> liftM (UEvalCmd . Command EvalExpr) expr
             <?> "top-level declaration"

explicitCommand :: Parser UDecl
explicitCommand = do
  symbol ":"
  cmdName <- identifier
  cmd <- case cmdName of
           "p"       -> return EvalExpr
           "t"       -> return GetType
           "passes"  -> return Passes
           "time"    -> return TimeIt
           "plot"    -> return Plot
           "plotmat" -> return PlotMat
           _   -> fail $ "unrecognized command: " ++ show cmdName
  e <- expr
  return $ UEvalCmd (Command cmd e)

-- typedAssignment :: Parser UDecl
-- typedAssignment = do
--   v <- try (identifier <* symbol "::")
--   ty <- typeExpr
--   (v', e) <- simpleDecl
--   if v' == v
--     then return $ TopAssign v (UAnnot e ty)
--     else fail $ "Type declaration variable must match assignment variable."

tryUnpackDecl :: Parser (Var, UExpr)
tryUnpackDecl = do
  v <- try (varName <* symbol "=" <* symbol "unpack")
  body <- expr
  return (v, body)

tryAssignDecl :: Parser (Var, UExpr)
tryAssignDecl = do
  (v, wrap) <- try $ do p <- varName
                        wrap <- idxLhsArgs <|> lamLhsArgs
                        symbol "="
                        return (p, wrap)
  body <- expr
  return (v, wrap body)

expr :: Parser UExpr
expr = makeExprParser (sc >> term >>= maybeAnnot) ops

term :: Parser UExpr
term =   parenRaw
     <|> varExpr
     <|> liftM ULit literal
     <|> declExpr
     <|> lamExpr
     <|> forExpr
     <?> "term"


maybeAnnot :: UExpr -> Parser UExpr
maybeAnnot e = do
  t <- optional typeAnnot
  return $ case t of
             Nothing -> e
             Just t -> UAnnot e t

typeAnnot :: Parser Type
typeAnnot = symbol "::" >> typeExpr

parenRaw = do
  elts <- parens $ expr `sepBy` symbol ","
  return $ case elts of
    [expr] -> expr
    elts -> URecCon $ Tup elts

-- maybeNamed :: Parser a -> Parser (Maybe String, a)
-- maybeNamed p = do
--   v <- optional $ try $
--     do v <- identifier
--        symbol "="
--        return v
--   x <- p
--   return (v, x)

varExpr :: Parser UExpr
varExpr = do
  s <- identifier
  return $ case strToBuiltin s of
    Just b -> UBuiltin b
    Nothing -> UVar (rawVar s)

declExpr :: Parser UExpr
declExpr = do
  symbol "let"
  bindings <- (unpackDecl <|> assignDecl) `sepBy` symbol ";"
  symbol "in"
  body <- expr
  return $ foldr unpackBinding body bindings
  where unpackBinding :: LocalDecl -> UExpr -> UExpr
        unpackBinding decl body = case decl of
          AssignDecl p binding -> ULet    p binding body
          UnpackDecl v binding -> UUnpack v binding body

lamExpr :: Parser UExpr
lamExpr = do
  symbol "lam"
  ps <- pat `sepBy` sc
  symbol ":"
  body <- expr
  return $ foldr ULam body ps

forExpr :: Parser UExpr
forExpr = do
  symbol "for"
  vs <- some idxPat -- `sepBy` sc
  symbol ":"
  body <- expr
  return $ foldr UFor body vs

-- decl :: Parser (UPat, UExpr)
unpackDecl :: Parser LocalDecl
unpackDecl = do
  v <- try (varName <* symbol "=" <* symbol "unpack")
  body <- expr
  return $ UnpackDecl v body

assignDecl :: Parser LocalDecl
assignDecl = do
  p <- pat
  wrap <- idxLhsArgs <|> lamLhsArgs
  symbol "="
  unpack <- optional (symbol "unpack")
  body <- expr
  return $ AssignDecl p (wrap body)

idxLhsArgs = do
  symbol "."
  args <- idxPat `sepBy` symbol "."
  return $ \body -> foldr UFor body args

lamLhsArgs = do
  args <- pat `sepBy` sc
  return $ \body -> foldr ULam body args

literal :: Parser LitVal
literal = lexeme $  fmap IntLit  (try (int <* notFollowedBy (symbol ".")))
                <|> fmap RealLit real
                <|> fmap StrLit stringLiteral

opNames = ["+", "*", "/", "-", "^"]
resNames = ["for", "lam", "let", "in", "unpack"]

identifier = makeIdentifier resNames

varName = liftM rawVar identifier
idxExpr = varName

appRule = InfixL (sc
                  *> notFollowedBy (choice . map symbol $ opNames)
                  >> return UApp)
binOpRule opchar builtin = InfixL (symbol opchar >> return binOpApp)
  where binOpApp e1 e2 = UApp (UApp (UBuiltin builtin) e1) e2

getRule = Postfix $ do
  vs  <- many $ symbol "." >> idxExpr
  return $ \body -> foldr (flip UGet) body (reverse vs)

ops = [ [getRule, appRule]
      , [binOpRule "^" Pow]
      , [binOpRule "*" Mul]  -- binOpRule "/" Div]
      , [binOpRule "+" Add, binOpRule "-" Sub]
      ]

-- idxExpr =   parenIdxExpr
--         <|> liftM (RecLeaf . FV) identifier

-- parenIdxExpr = do
--   elts <- parens $ maybeNamed idxExpr `sepBy` symbol ","
--   return $ case elts of
--     [(Nothing, expr)] -> expr
--     elts -> RecTree $ mixedRecord elts

idxPat :: Parser Var
idxPat = liftM rawVar identifier

pat :: Parser UPat
pat =   parenPat
    <|> liftM RecLeaf varName -- (optional typeAnnot)

parenPat :: Parser UPat
parenPat = do
  xs <- parens $ pat `sepBy` symbol ","
  return $ case xs of
    [x] -> x
    xs -> RecTree $ Tup xs

typeExpr :: Parser Type
typeExpr = makeExprParser (sc >> typeExpr') typeOps

var :: Parser Var
var = liftM rawVar $ makeIdentifier
            ["Int", "Real", "Bool", "Str", "A", "E"]

-- forallType :: Parser Type
-- forallType = do
--   try $ symbol "A"
--   vars <- identifier `sepBy` sc
--   symbol "."
--   body <- typeExpr
--   return $ NamedForall vars body

-- existsType :: Parser Type
-- existsType = do
--   try $ symbol "E"
--   var <- identifier
--   symbol "."
--   body <- typeExpr
--   return $ NamedExists var body

baseType :: Parser BaseType
baseType = (symbol "Int"  >> return IntType)
       <|> (symbol "Real" >> return RealType)
       <|> (symbol "Bool" >> return BoolType)
       <|> (symbol "Str"  >> return StrType)
       <?> "base type"

-- typeOps = [ [InfixR (symbol "=>" >> return TabType)]
--           , [InfixR (symbol "->" >> return ArrType)]]
typeOps = [ [InfixR (symbol "->" >> return ArrType)]]

typeExpr' =   parens typeExpr
          <|> liftM TypeVar varName
          <|> liftM BaseType baseType
          -- <|> forallType
          -- <|> existsType
          <?> "term"

-- data BoundVars = BoundVars { lVars :: [Var]
--                            , tVars :: [Var] }

-- lowerInstr :: UDecl -> UDecl
-- lowerInstr = fmap (lower empty)
--   where empty = BoundVars [] []

-- lower :: BoundVars -> UExpr -> UExpr
-- lower env expr = case expr of
--   ULit c         -> ULit c
--   UVar v         -> UVar $ toDeBruijn (lVars env) v
--   UBuiltin b     -> UBuiltin b
--   ULet p e body  -> ULet p (recur e) $ lowerWithMany p body
--   ULam p body    -> ULam p           $ lowerWithMany p body
--   UApp fexpr arg -> UApp (recur fexpr) (recur arg)
--   UFor p body    -> UFor p           $ lowerWith p body
--   UGet e ie      -> UGet (recur e) $ toDeBruijn (lVars env) ie
--   URecCon r      -> URecCon $ fmap recur r
--   UAnnot e t     -> UAnnot (recur e) (lowerType env t)
--   UUnpack v e body -> UUnpack v (recur e) $
--                          lower (env {lVars = v : lVars env}) body
--   where recur = lower env
--         lowerWith p expr = lower (updateLVar p env) expr
--         lowerWithMany p expr = lower (updateLVars (toList p) env) expr

--         updateLVar :: Var -> BoundVars -> BoundVars
--         updateLVar v env = env {lVars = v : lVars env}

--         updateLVars :: [Var] -> BoundVars -> BoundVars
--         updateLVars vs env = env {lVars = vs ++ lVars env}

-- lowerType :: BoundVars -> Type -> Type
-- lowerType env ty = case ty of
--   BaseType b    -> BaseType b
--   TypeVar v     -> TypeVar $ toDeBruijn (tVars env) v
--   ArrType t1 t2 -> ArrType (recur t1) (recur t2)
--   TabType t1 t2 -> TabType (recur t1) (recur t2)
--   -- MetaTypeVar m -> MetaTypeVar m
--   where recur = lowerType env

-- updateTVars :: [Var] -> BoundVars -> BoundVars
-- updateTVars vs env = env {tVars = vs ++ tVars env}

-- -- boundVarPass :: Pass UExpr UExpr () ()
-- -- boundVarPass = Pass
-- --   { lowerExpr   = \expr env -> do liftErrIO $ checkBoundVarsExpr expr env
-- --                                   return ((), expr)
-- --   , lowerUnpack = \_ expr env -> do liftErrIO $ checkBoundVarsExpr expr env
-- --                                     return ((), (), expr)
-- --   , lowerCmd    = \cmd  env -> return $ checkBoundVarsCmd cmd env }

-- checkBoundVarsCmd :: Command UExpr -> Vars -> Command UExpr
-- checkBoundVarsCmd cmd@(Command cmdName expr) envVars =
--   case checkBoundVarsExpr expr envVars of
--     Left err -> CmdErr err
--     Right () -> cmd
-- checkBoundVarsCmd x _ = x

-- checkBoundVarsExpr :: UExpr -> Vars -> Except ()
-- checkBoundVarsExpr expr envVars = do
--   let freeVars = fvsUExpr expr
--   lEnv envVars `contains` lEnv freeVars
--   tEnv envVars `contains` tEnv freeVars
--   return ()
--   where contains :: Env i a -> Env i a -> Except ()
--         contains e1 e2 = case fVars (e2 `envDiff` e1) of
--                             v:_ -> Left $ UnboundVarErr v
--                             [] -> Right ()
