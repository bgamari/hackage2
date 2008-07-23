{
{-# OPTIONS_GHC -w #-}
module Distribution.Server.Pages.Package.HaddockParse (parseParas) where

import Distribution.Server.Pages.Package.HaddockLex
import Distribution.Server.Pages.Package.HaddockHtml

import Control.Monad.Error	()
}

%tokentype { Token }

%token	'/'	{ TokSpecial '/' }
	'@'	{ TokSpecial '@' }
	'['     { TokDefStart }
	']'     { TokDefEnd }
	DQUO 	{ TokSpecial '\"' }
	URL	{ TokURL $$ }
        PIC     { TokPic $$ }
	ANAME	{ TokAName $$ }
	'-'	{ TokBullet }
	'(n)'	{ TokNumber }
	'>..'	{ TokBirdTrack $$ }
	IDENT   { TokIdent $$ }
	PARA    { TokPara }
	STRING	{ TokString $$ }

%monad { Either String }

%name parseParas  doc
%name parseString seq

%%

doc	:: { Doc }
	: apara PARA doc	{ docAppend $1 $3 }
	| PARA doc 		{ $2 }
	| apara			{ $1 }
	| {- empty -}		{ DocEmpty }

apara	:: { Doc }
	: ulpara		{ DocUnorderedList [$1] }
	| olpara		{ DocOrderedList [$1] }
        | defpara               { DocDefList [$1] }
	| para			{ $1 }

ulpara  :: { Doc }
	: '-' para		{ $2 }

olpara  :: { Doc } 
	: '(n)' para		{ $2 }

defpara :: { (Doc,Doc) }
	: '[' seq ']' seq	{ ($2, $4) }

para    :: { Doc }
	: seq			{ docParagraph $1 }
	| codepara		{ DocCodeBlock $1 }

codepara :: { Doc }
	: '>..' codepara	{ docAppend (DocString $1) $2 }
	| '>..'			{ DocString $1 }

seq	:: { Doc }
	: elem seq		{ docAppend $1 $2 }
	| elem			{ $1 }

elem	:: { Doc }
	: elem1			{ $1 }
	| '@' seq1 '@'		{ DocMonospaced $2 }

seq1	:: { Doc }
	: elem1 seq1		{ docAppend $1 $2 }
	| elem1			{ $1 }

elem1	:: { Doc }
	: STRING		{ DocString $1 }
	| '/' strings '/'	{ DocEmphasis (DocString $2) }
	| URL			{ DocURL $1 }
        | PIC                   { DocPic $1 }
	| ANAME			{ DocAName $1 }
	| IDENT			{ DocIdentifier $1 }
	| DQUO strings DQUO	{ DocModule $2 }

strings  :: { String }
	: STRING		{ $1 }
	| STRING strings	{ $1 ++ $2 }

{
happyError :: [Token] -> Either String a
happyError toks = 
  Left ("parse error in doc string: "  ++ show (take 3 toks))
}
