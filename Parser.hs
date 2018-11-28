module Parser (VarName, IdxVarName, Expr (..), Pat (..),
               IdxPat, IdxExpr (..), parseCommand, typedName,
               str, Command (..)) where
import Util
import Record
import Typer
import qualified Syntax as S

import Control.Monad
import Test.HUnit
import qualified Data.Map.Strict as M
import Text.ParserCombinators.Parsec hiding (lower)
import Text.ParserCombinators.Parsec.Expr
import Text.ParserCombinators.Parsec.Language
import qualified Text.ParserCombinators.Parsec.Token as Token

data Expr = Lit S.LitVal
          | Var VarName
          | Let Pat Expr Expr
          | Lam Pat Expr
          | App Expr Expr
          | For IdxPat Expr
          | Get Expr IdxExpr
          | RecCon (Record Expr)
              deriving (Show, Eq)

data IdxExpr = IdxVar IdxVarName
             | IdxRecCon (Record IdxExpr)
                 deriving (Show, Eq)

type IdxPat = Pat
data Pat = VarPat VarName
         | RecPat (Record Pat) deriving (Show, Eq)

data Command = GetType    Expr
             | GetParse   Expr
             | GetLowered Expr
             | EvalExpr   Expr
             | EvalDecl   Pat Expr deriving (Show, Eq)


type VarName = String
type IdxVarName = String
type Decl = (Pat, Expr)

parseCommand :: String -> Either ParseError Command
parseCommand s = parse (command <* eof) "" s

command :: Parser Command
command =   explicitCommand
        <|> liftM (uncurry EvalDecl) (try decl)
        <|> liftM EvalExpr expr
        <?> "command"

opNames = ["+", "*", "/", "-", "^"]
resNames = ["for", "lam", "let", "in"]
languageDef = haskellStyle { Token.reservedOpNames = opNames
                           , Token.reservedNames   = resNames
                           }

lexer = Token.makeTokenParser languageDef
identifier = Token.identifier lexer
parens     = Token.parens     lexer
lexeme     = Token.lexeme     lexer
brackets   = Token.brackets   lexer
integer    = Token.integer    lexer
whiteSpace = Token.whiteSpace lexer
reservedOp = Token.reservedOp lexer

appRule = Infix (whiteSpace
                 *> notFollowedBy (choice . map reservedOp $ opNames ++ resNames)
                 >> return App) AssocLeft
binOpRule opchar opname = Infix (reservedOp opchar
                                 >> return (binOpApp opname)) AssocLeft

binOpApp :: String -> Expr -> Expr -> Expr
binOpApp s e1 e2 = App (App (Var s) e1) e2

getRule = Postfix $ do
  vs  <- many $ str "." >> idxExpr
  return $ \body -> foldr (flip Get) body (reverse vs)

ops = [ [getRule, appRule]
      , [binOpRule "^" "pow"]
      , [binOpRule "*" "mul", binOpRule "/" "div"]
      , [binOpRule "+" "add", binOpRule "-" "sub"]
      ]

term =   parenExpr
     <|> liftM Var identifier
     <|> liftM (Lit . S.IntLit . fromIntegral) integer
     <|> letExpr
     <|> lamExpr
     <|> forExpr
     <?> "term"

str = lexeme . string
var = liftM id identifier

idxPat = pat
idxExpr =   parenIdxExpr
        <|> liftM IdxVar identifier

pat :: Parser Pat
pat =   parenPat
    <|> liftM VarPat identifier

parenPat :: Parser Pat
parenPat = do
  xs <- parens $ maybeNamed pat `sepBy` str ","
  return $ case xs of
    [(Nothing, x)] -> x
    xs -> RecPat $ mixedRecord xs

expr :: Parser Expr
expr = buildExpressionParser ops (whiteSpace >> term)

decl :: Parser Decl
decl = do
  v <- pat
  wrap <- idxLhsArgs <|> lamLhsArgs
  str "="
  body <- expr
  return (v, wrap body)

typedName :: Parser (String, BaseType)
typedName = do
  name <- identifier
  str "::"
  typeName <- identifier
  ty <- case typeName of
    "Int"  -> return IntType
    "Str"  -> return StrType
    "Real" -> return RealType
    _      -> fail $ show typeName ++ " is not a valid type"
  return (name, ty)

explicitCommand :: Parser Command
explicitCommand = do
  try $ str ":"
  cmd <- identifier
  e <- expr
  case cmd of
    "t" -> return $ GetType e
    "p" -> return $ GetParse e
    "l" -> return $ GetLowered e
    _   -> fail $ "unrecognized command: " ++ show cmd

maybeNamed :: Parser a -> Parser (Maybe String, a)
maybeNamed p = do
  v <- optionMaybe $ try $
    do v <- identifier
       str "="
       return v
  x <- p
  return (v, x)

parenIdxExpr = do
  elts <- parens $ maybeNamed idxExpr `sepBy` str ","
  return $ case elts of
    [(Nothing, expr)] -> expr
    elts -> IdxRecCon $ mixedRecord elts

parenExpr = do
  elts <- parens $ maybeNamed expr `sepBy` str ","
  return $ case elts of
    [(Nothing, expr)] -> expr
    elts -> RecCon $ mixedRecord elts

idxLhsArgs = do
  try $ str "."
  args <- idxPat `sepBy` str "."
  return $ \body -> foldr For body args

lamLhsArgs = do
  args <- pat `sepBy` whiteSpace
  return $ \body -> foldr Lam body args

letExpr = do
  try $ str "let"
  bindings <- decl `sepBy` str ";"
  str "in"
  body <- expr
  return $ foldr (uncurry Let) body bindings

lamExpr = do
  try $ str "lam"
  ps <- pat `sepBy` whiteSpace
  str ":"
  body <- expr
  return $ foldr Lam body ps

forExpr = do
  try $ str "for"
  vs <- idxPat `sepBy` whiteSpace
  str ":"
  body <- expr
  return $ foldr For body vs
