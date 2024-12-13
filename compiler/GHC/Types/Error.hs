{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

module GHC.Types.Error
   ( -- * Messages
     Messages
   , mkMessages
   , getMessages
   , emptyMessages
   , isEmptyMessages
   , singleMessage
   , addMessage
   , unionMessages
   , unionManyMessages
   , MsgEnvelope (..)

   -- * Classifying Messages

   , MessageClass (..)
   , Severity (..)
   , Diagnostic (..)
   , UnknownDiagnostic (..)
   , DiagnosticMessage (..)
   , DiagnosticReason (..)
   , DiagnosticHint (..)
   , mkPlainDiagnostic
   , mkPlainError
   , mkDecoratedDiagnostic
   , mkDecoratedError

   , NoDiagnosticOpts(..)

   -- * Hints and refactoring actions
   , GhcHint (..)
   , AvailableBindings(..)
   , LanguageExtensionHint(..)
   , suggestExtension
   , suggestExtensionWithInfo
   , suggestExtensions
   , suggestExtensionsWithInfo
   , suggestAnyExtension
   , suggestAnyExtensionWithInfo
   , useExtensionInOrderTo
   , noHints

    -- * Rendering Messages

   , SDoc
   , DecoratedSDoc (unDecorated)
   , mkDecorated, mkSimpleDecorated
   , unionDecoratedSDoc
   , mapDecoratedSDoc

   , pprMessageBag
   , mkLocMessage
   , mkLocMessageWarningGroups
   , getCaretDiagnostic
   -- * Queries
   , isIntrinsicErrorMessage
   , isExtrinsicErrorMessage
   , isWarningMessage
   , getErrorMessages
   , getWarningMessages
   , partitionMessages
   , errorsFound
   , errorsOrFatalWarningsFound

   -- * Diagnostic codes
   , DiagnosticCode(..)
   )
where

import GHC.Prelude

import GHC.Driver.Flags

import GHC.Data.Bag
import GHC.IO (catchException)
import GHC.Utils.Outputable as Outputable
import qualified GHC.Utils.Ppr.Colour as Col
import GHC.Types.SrcLoc as SrcLoc
import GHC.Types.Hint
import GHC.Data.FastString (unpackFS)
import GHC.Data.StringBuffer (atLine, hGetStringBuffer, len, lexemeToString)
import GHC.Utils.Json
import GHC.Utils.Panic

import Data.Bifunctor
import Data.Foldable    ( fold )
import qualified Data.List.NonEmpty as NE
import Data.List ( intercalate )
import Data.Typeable ( Typeable )
import Numeric.Natural ( Natural )
import Text.Printf ( printf )

{-
Note [Messages]
~~~~~~~~~~~~~~~

We represent the 'Messages' as a single bag of warnings and errors.

The reason behind that is that there is a fluid relationship between errors
and warnings and we want to be able to promote or demote errors and warnings
based on certain flags (e.g. -Werror, -fdefer-type-errors or
-XPartialTypeSignatures). More specifically, every diagnostic has a
'DiagnosticReason', but a warning 'DiagnosticReason' might be associated with
'SevError', in the case of -Werror.

We rely on the 'Severity' to distinguish between a warning and an error.

'WarningMessages' and 'ErrorMessages' are for now simple type aliases to
retain backward compatibility, but in future iterations these can be either
parameterised over an 'e' message type (to make type signatures a bit more
declarative) or removed altogether.
-}

-- | A collection of messages emitted by GHC during error reporting. A
-- diagnostic message is typically a warning or an error. See Note [Messages].
--
-- /INVARIANT/: All the messages in this collection must be relevant, i.e.
-- their 'Severity' should /not/ be 'SevIgnore'. The smart constructor
-- 'mkMessages' will filter out any message which 'Severity' is 'SevIgnore'.
newtype Messages e = Messages { getMessages :: Bag (MsgEnvelope e) }
  deriving newtype (Semigroup, Monoid)
  deriving stock (Functor, Foldable, Traversable)

emptyMessages :: Messages e
emptyMessages = Messages emptyBag

mkMessages :: Bag (MsgEnvelope e) -> Messages e
mkMessages = Messages . filterBag interesting
  where
    interesting :: MsgEnvelope e -> Bool
    interesting = (/=) SevIgnore . errMsgSeverity

isEmptyMessages :: Messages e -> Bool
isEmptyMessages (Messages msgs) = isEmptyBag msgs

singleMessage :: MsgEnvelope e -> Messages e
singleMessage e = addMessage e emptyMessages

instance Diagnostic e => Outputable (Messages e) where
  ppr msgs = braces (vcat (map ppr_one (bagToList (getMessages msgs))))
     where
       ppr_one :: MsgEnvelope e -> SDoc
       ppr_one envelope = pprDiagnostic (errMsgDiagnostic envelope)

{- Note [Discarding Messages]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Discarding a 'SevIgnore' message from 'addMessage' and 'unionMessages' is just
an optimisation, as GHC would /also/ suppress any diagnostic which severity is
'SevIgnore' before printing the message: See for example 'putLogMsg' and
'defaultLogAction'.

-}

-- | Adds a 'Message' to the input collection of messages.
-- See Note [Discarding Messages].
addMessage :: MsgEnvelope e -> Messages e -> Messages e
addMessage x (Messages xs)
  | SevIgnore <- errMsgSeverity x = Messages xs
  | otherwise                     = Messages (x `consBag` xs)

-- | Joins two collections of messages together.
-- See Note [Discarding Messages].
unionMessages :: Messages e -> Messages e -> Messages e
unionMessages (Messages msgs1) (Messages msgs2) =
  Messages (msgs1 `unionBags` msgs2)

-- | Joins many 'Messages's together
unionManyMessages :: Foldable f => f (Messages e) -> Messages e
unionManyMessages = fold

-- | A 'DecoratedSDoc' is isomorphic to a '[SDoc]' but it carries the
-- invariant that the input '[SDoc]' needs to be rendered /decorated/ into its
-- final form, where the typical case would be adding bullets between each
-- elements of the list. The type of decoration depends on the formatting
-- function used, but in practice GHC uses the 'formatBulleted'.
newtype DecoratedSDoc = Decorated { unDecorated :: [SDoc] }

-- | Creates a new 'DecoratedSDoc' out of a list of 'SDoc'.
mkDecorated :: [SDoc] -> DecoratedSDoc
mkDecorated = Decorated

-- | Creates a new 'DecoratedSDoc' out of a single 'SDoc'
mkSimpleDecorated :: SDoc -> DecoratedSDoc
mkSimpleDecorated doc = Decorated [doc]

-- | Joins two 'DecoratedSDoc' together. The resulting 'DecoratedSDoc'
-- will have a number of entries which is the sum of the lengths of
-- the input.
unionDecoratedSDoc :: DecoratedSDoc -> DecoratedSDoc -> DecoratedSDoc
unionDecoratedSDoc (Decorated s1) (Decorated s2) =
  Decorated (s1 `mappend` s2)

-- | Apply a transformation function to all elements of a 'DecoratedSDoc'.
mapDecoratedSDoc :: (SDoc -> SDoc) -> DecoratedSDoc -> DecoratedSDoc
mapDecoratedSDoc f (Decorated s1) =
  Decorated (map f s1)

-- | A class identifying a diagnostic.
-- Dictionary.com defines a diagnostic as:
--
-- \"a message output by a computer diagnosing an error in a computer program,
-- computer system, or component device\".
--
-- A 'Diagnostic' carries the /actual/ description of the message (which, in
-- GHC's case, it can be an error or a warning) and the /reason/ why such
-- message was generated in the first place.
class Diagnostic a where

  -- | Type of configuration options for the diagnostic.
  type DiagnosticOpts a
  defaultDiagnosticOpts :: DiagnosticOpts a

  -- | Extract the error message text from a 'Diagnostic'.
  diagnosticMessage :: DiagnosticOpts a -> a -> DecoratedSDoc

  -- | Extract the reason for this diagnostic. For warnings,
  -- a 'DiagnosticReason' includes the warning flag.
  diagnosticReason  :: a -> DiagnosticReason

  -- | Extract any hints a user might use to repair their
  -- code to avoid this diagnostic.
  diagnosticHints   :: a -> [GhcHint]

  -- | Get the 'DiagnosticCode' associated with this 'Diagnostic'.
  -- This can return 'Nothing' for at least two reasons:
  --
  -- 1. The message might be from a plugin that does not supply codes.
  -- 2. The message might not yet have been assigned a code. See the
  --    'Diagnostic' instance for 'DiagnosticMessage'.
  --
  -- Ideally, case (2) would not happen, but because
  -- some errors in GHC still use the old system of just writing the
  -- error message in-place (instead of using a dedicated error type
  -- and constructor), we do not have error codes for all errors.
  -- #18516 tracks our progress toward this goal.
  diagnosticCode    :: a -> Maybe DiagnosticCode

-- | An existential wrapper around an unknown diagnostic.
data UnknownDiagnostic where
  UnknownDiagnostic :: (DiagnosticOpts a ~ NoDiagnosticOpts, Diagnostic a, Typeable a)
                    => a -> UnknownDiagnostic

instance Diagnostic UnknownDiagnostic where
  type DiagnosticOpts UnknownDiagnostic = NoDiagnosticOpts
  defaultDiagnosticOpts = NoDiagnosticOpts
  diagnosticMessage _ (UnknownDiagnostic diag) = diagnosticMessage NoDiagnosticOpts diag
  diagnosticReason    (UnknownDiagnostic diag) = diagnosticReason  diag
  diagnosticHints     (UnknownDiagnostic diag) = diagnosticHints   diag
  diagnosticCode      (UnknownDiagnostic diag) = diagnosticCode    diag

-- A fallback 'DiagnosticOpts' which can be used when there are no options
-- for a particular diagnostic.
data NoDiagnosticOpts = NoDiagnosticOpts

pprDiagnostic :: forall e . Diagnostic e => e -> SDoc
pprDiagnostic e = vcat [ ppr (diagnosticReason e)
                       , nest 2 (vcat (unDecorated (diagnosticMessage opts e))) ]
  where opts = defaultDiagnosticOpts @e

-- | A generic 'Hint' message, to be used with 'DiagnosticMessage'.
data DiagnosticHint = DiagnosticHint !SDoc

instance Outputable DiagnosticHint where
  ppr (DiagnosticHint msg) = msg

-- | A generic 'Diagnostic' message, without any further classification or
-- provenance: By looking at a 'DiagnosticMessage' we don't know neither
-- /where/ it was generated nor how to intepret its payload (as it's just a
-- structured document). All we can do is to print it out and look at its
-- 'DiagnosticReason'.
data DiagnosticMessage = DiagnosticMessage
  { diagMessage :: !DecoratedSDoc
  , diagReason  :: !DiagnosticReason
  , diagHints   :: [GhcHint]
  }

instance Diagnostic DiagnosticMessage where
  type DiagnosticOpts DiagnosticMessage = NoDiagnosticOpts
  defaultDiagnosticOpts = NoDiagnosticOpts
  diagnosticMessage _ = diagMessage
  diagnosticReason  = diagReason
  diagnosticHints   = diagHints
  diagnosticCode _  = Nothing

-- | Helper function to use when no hints can be provided. Currently this function
-- can be used to construct plain 'DiagnosticMessage' and add hints to them, but
-- once #18516 will be fully executed, the main usage of this function would be in
-- the implementation of the 'diagnosticHints' typeclass method, to report the fact
-- that a particular 'Diagnostic' has no hints.
noHints :: [GhcHint]
noHints = mempty

mkPlainDiagnostic :: DiagnosticReason -> [GhcHint] -> SDoc -> DiagnosticMessage
mkPlainDiagnostic rea hints doc = DiagnosticMessage (mkSimpleDecorated doc) rea hints

-- | Create an error 'DiagnosticMessage' holding just a single 'SDoc'
mkPlainError :: [GhcHint] -> SDoc -> DiagnosticMessage
mkPlainError hints doc = DiagnosticMessage (mkSimpleDecorated doc) ErrorWithoutFlag hints

-- | Create a 'DiagnosticMessage' from a list of bulleted SDocs and a 'DiagnosticReason'
mkDecoratedDiagnostic :: DiagnosticReason -> [GhcHint] -> [SDoc] -> DiagnosticMessage
mkDecoratedDiagnostic rea hints docs = DiagnosticMessage (mkDecorated docs) rea hints

-- | Create an error 'DiagnosticMessage' from a list of bulleted SDocs
mkDecoratedError :: [GhcHint] -> [SDoc] -> DiagnosticMessage
mkDecoratedError hints docs = DiagnosticMessage (mkDecorated docs) ErrorWithoutFlag hints

-- | The reason /why/ a 'Diagnostic' was emitted in the first place.
-- Diagnostic messages are born within GHC with a very precise reason, which
-- can be completely statically-computed (i.e. this is an error or a warning
-- no matter what), or influenced by the specific state of the 'DynFlags' at
-- the moment of the creation of a new 'Diagnostic'. For example, a parsing
-- error is /always/ going to be an error, whereas a 'WarningWithoutFlag
-- Opt_WarnUnusedImports' might turn into an error due to '-Werror' or
-- '-Werror=warn-unused-imports'. Interpreting a 'DiagnosticReason' together
-- with its associated 'Severity' gives us the full picture.
data DiagnosticReason
  = WarningWithoutFlag
  -- ^ Born as a warning.
  | WarningWithFlag !WarningFlag
  -- ^ Warning was enabled with the flag.
  | ErrorWithoutFlag
  -- ^ Born as an error.
  deriving (Eq, Show)

instance Outputable DiagnosticReason where
  ppr = \case
    WarningWithoutFlag  -> text "WarningWithoutFlag"
    WarningWithFlag wf  -> text ("WarningWithFlag " ++ show wf)
    ErrorWithoutFlag    -> text "ErrorWithoutFlag"

-- | An envelope for GHC's facts about a running program, parameterised over the
-- /domain-specific/ (i.e. parsing, typecheck-renaming, etc) diagnostics.
--
-- To say things differently, GHC emits /diagnostics/ about the running
-- program, each of which is wrapped into a 'MsgEnvelope' that carries
-- specific information like where the error happened, etc. Finally, multiple
-- 'MsgEnvelope's are aggregated into 'Messages' that are returned to the
-- user.
data MsgEnvelope e = MsgEnvelope
   { errMsgSpan        :: SrcSpan
      -- ^ The SrcSpan is used for sorting errors into line-number order
   , errMsgContext     :: NamePprCtx
   , errMsgDiagnostic  :: e
   , errMsgSeverity    :: Severity
   } deriving (Functor, Foldable, Traversable)

-- | The class for a diagnostic message. The main purpose is to classify a
-- message within GHC, to distinguish it from a debug/dump message vs a proper
-- diagnostic, for which we include a 'DiagnosticReason'.
data MessageClass
  = MCOutput
  | MCFatal
  | MCInteractive

  | MCDump
    -- ^ Log message intended for compiler developers
    -- No file\/line\/column stuff

  | MCInfo
    -- ^ Log messages intended for end users.
    -- No file\/line\/column stuff.

  | MCDiagnostic Severity DiagnosticReason (Maybe DiagnosticCode)
    -- ^ Diagnostics from the compiler. This constructor is very powerful as
    -- it allows the construction of a 'MessageClass' with a completely
    -- arbitrary permutation of 'Severity' and 'DiagnosticReason'. As such,
    -- users are encouraged to use the 'mkMCDiagnostic' smart constructor
    -- instead. Use this constructor directly only if you need to construct
    -- and manipulate diagnostic messages directly, for example inside
    -- 'GHC.Utils.Error'. In all the other circumstances, /especially/ when
    -- emitting compiler diagnostics, use the smart constructor.
    --
    -- The @Maybe 'DiagnosticCode'@ field carries a code (if available) for
    -- this diagnostic. If you are creating a message not tied to any
    -- error-message type, then use Nothing. In the long run, this really
    -- should always have a 'DiagnosticCode'. See Note [Diagnostic codes].

{-
Note [Suppressing Messages]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
The 'SevIgnore' constructor is used to generate messages for diagnostics which
are meant to be suppressed and not reported to the user: the classic example
are warnings for which the user didn't enable the corresponding 'WarningFlag',
so GHC shouldn't print them.

A different approach would be to extend the zoo of 'mkMsgEnvelope' functions
to return a 'Maybe (MsgEnvelope e)', so that we won't need to even create the
message to begin with. Both approaches have been evaluated, but we settled on
the "SevIgnore one" for a number of reasons:

* It's less invasive to deal with;
* It plays slightly better with deferred diagnostics (see 'GHC.Tc.Errors') as
  for those we need to be able to /always/ produce a message (so that is
  reported at runtime);
* It gives us more freedom: we can still decide to drop a 'SevIgnore' message
  at leisure, or we can decide to keep it around until the last moment. Maybe
  in the future we would need to turn a 'SevIgnore' into something else, for
  example to "unsuppress" diagnostics if a flag is set: with this approach, we
  have more leeway to accommodate new features.

-}


-- | Used to describe warnings and errors
--   o The message has a file\/line\/column heading,
--     plus "warning:" or "error:",
--     added by mkLocMessage
--   o With 'SevIgnore' the message is suppressed
--   o Output is intended for end users
data Severity
  = SevIgnore
  -- ^ Ignore this message, for example in
  -- case of suppression of warnings users
  -- don't want to see. See Note [Suppressing Messages]
  | SevWarning
  | SevError
  deriving (Eq, Show)

instance Outputable Severity where
  ppr = \case
    SevIgnore  -> text "SevIgnore"
    SevWarning -> text "SevWarning"
    SevError   -> text "SevError"

instance ToJson Severity where
  json s = JSString (show s)

instance ToJson MessageClass where
  json MCOutput = JSString "MCOutput"
  json MCFatal  = JSString "MCFatal"
  json MCInteractive = JSString "MCInteractive"
  json MCDump = JSString "MCDump"
  json MCInfo = JSString "MCInfo"
  json (MCDiagnostic sev reason code) =
    JSString $ renderWithContext defaultSDocContext (ppr $ text "MCDiagnostic" <+> ppr sev <+> ppr reason <+> ppr code)

instance Show (MsgEnvelope DiagnosticMessage) where
    show = showMsgEnvelope

-- | Shows an 'MsgEnvelope'. Only use this for debugging.
showMsgEnvelope :: forall a . Diagnostic a => MsgEnvelope a -> String
showMsgEnvelope err =
  renderWithContext defaultSDocContext (vcat (unDecorated . (diagnosticMessage (defaultDiagnosticOpts @a)) $ errMsgDiagnostic err))

pprMessageBag :: Bag SDoc -> SDoc
pprMessageBag msgs = vcat (punctuate blankLine (bagToList msgs))

mkLocMessage
  :: MessageClass                       -- ^ What kind of message?
  -> SrcSpan                            -- ^ location
  -> SDoc                               -- ^ message
  -> SDoc
mkLocMessage = mkLocMessageWarningGroups True

-- | Make an error message with location info, specifying whether to show
-- warning groups (if applicable).
mkLocMessageWarningGroups
  :: Bool                               -- ^ Print warning groups (if applicable)?
  -> MessageClass                       -- ^ What kind of message?
  -> SrcSpan                            -- ^ location
  -> SDoc                               -- ^ message
  -> SDoc
  -- Always print the location, even if it is unhelpful.  Error messages
  -- are supposed to be in a standard format, and one without a location
  -- would look strange.  Better to say explicitly "<no location info>".
mkLocMessageWarningGroups show_warn_groups msg_class locn msg
    = sdocOption sdocColScheme $ \col_scheme ->
      let locn' = sdocOption sdocErrorSpans $ \case
                     True  -> ppr locn
                     False -> ppr (srcSpanStart locn)

          msg_colour = getMessageClassColour msg_class col_scheme
          col = coloured msg_colour . text

          msg_title = coloured msg_colour $
            case msg_class of
              MCDiagnostic SevError   _ _ -> text "error"
              MCDiagnostic SevWarning _ _ -> text "warning"
              MCFatal                     -> text "fatal"
              _                           -> empty

          warning_flag_doc =
            case msg_class of
              MCDiagnostic sev reason _code
                | Just msg <- flag_msg sev reason -> brackets msg
              _                                   -> empty

          code_doc =
            case msg_class of
              MCDiagnostic _ _ (Just code) -> brackets (coloured msg_colour $ ppr code)
              _                            -> empty

          flag_msg :: Severity -> DiagnosticReason -> Maybe SDoc
          flag_msg SevIgnore _                 = Nothing
            -- The above can happen when displaying an error message
            -- in a log file, e.g. with -ddump-tc-trace. It should not
            -- happen otherwise, though.
          flag_msg SevError WarningWithoutFlag = Just (col "-Werror")
          flag_msg SevError (WarningWithFlag wflag) =
            let name = NE.head (warnFlagNames wflag) in
            Just $ col ("-W" ++ name) <+> warn_flag_grp wflag
                                      <> comma
                                      <+> col ("Werror=" ++ name)
          flag_msg SevError   ErrorWithoutFlag   = Nothing
          flag_msg SevWarning WarningWithoutFlag = Nothing
          flag_msg SevWarning (WarningWithFlag wflag) =
            let name = NE.head (warnFlagNames wflag) in
            Just (col ("-W" ++ name) <+> warn_flag_grp wflag)
          flag_msg SevWarning ErrorWithoutFlag =
            pprPanic "SevWarning with ErrorWithoutFlag" $
              vcat [ text "locn:" <+> ppr locn
                   , text "msg:" <+> ppr msg ]

          warn_flag_grp flag
              | show_warn_groups =
                    case smallestWarningGroups flag of
                        [] -> empty
                        groups -> text $ "(in " ++ intercalate ", " (map ("-W"++) groups) ++ ")"
              | otherwise = empty

          -- Add prefixes, like    Foo.hs:34: warning:
          --                           <the warning message>
          header = locn' <> colon <+>
                   msg_title <> colon <+>
                   code_doc <+> warning_flag_doc

      in coloured (Col.sMessage col_scheme)
                  (hang (coloured (Col.sHeader col_scheme) header) 4
                        msg)

getMessageClassColour :: MessageClass -> Col.Scheme -> Col.PprColour
getMessageClassColour (MCDiagnostic SevError _reason _code)   = Col.sError
getMessageClassColour (MCDiagnostic SevWarning _reason _code) = Col.sWarning
getMessageClassColour MCFatal                                 = Col.sFatal
getMessageClassColour _                                       = const mempty

getCaretDiagnostic :: MessageClass -> SrcSpan -> IO SDoc
getCaretDiagnostic _ (UnhelpfulSpan _) = pure empty
getCaretDiagnostic msg_class (RealSrcSpan span _) =
  caretDiagnostic <$> getSrcLine (srcSpanFile span) row
  where
    getSrcLine fn i =
      getLine i (unpackFS fn)
        `catchException` \(_ :: IOError) ->
          pure Nothing

    getLine i fn = do
      -- StringBuffer has advantages over readFile:
      -- (a) no lazy IO, otherwise IO exceptions may occur in pure code
      -- (b) always UTF-8, rather than some system-dependent encoding
      --     (Haskell source code must be UTF-8 anyway)
      content <- hGetStringBuffer fn
      case atLine i content of
        Just at_line -> pure $
          case lines (fix <$> lexemeToString at_line (len at_line)) of
            srcLine : _ -> Just srcLine
            _           -> Nothing
        _ -> pure Nothing

    -- allow user to visibly see that their code is incorrectly encoded
    -- (StringBuffer.nextChar uses \0 to represent undecodable characters)
    fix '\0' = '\xfffd'
    fix c    = c

    row = srcSpanStartLine span
    rowStr = show row
    multiline = row /= srcSpanEndLine span

    caretDiagnostic Nothing = empty
    caretDiagnostic (Just srcLineWithNewline) =
      sdocOption sdocColScheme$ \col_scheme ->
      let sevColour = getMessageClassColour msg_class col_scheme
          marginColour = Col.sMargin col_scheme
      in
      coloured marginColour (text marginSpace) <>
      text ("\n") <>
      coloured marginColour (text marginRow) <>
      text (" " ++ srcLinePre) <>
      coloured sevColour (text srcLineSpan) <>
      text (srcLinePost ++ "\n") <>
      coloured marginColour (text marginSpace) <>
      coloured sevColour (text (" " ++ caretLine))

      where

        -- expand tabs in a device-independent manner #13664
        expandTabs tabWidth i s =
          case s of
            ""        -> ""
            '\t' : cs -> replicate effectiveWidth ' ' ++
                         expandTabs tabWidth (i + effectiveWidth) cs
            c    : cs -> c : expandTabs tabWidth (i + 1) cs
          where effectiveWidth = tabWidth - i `mod` tabWidth

        srcLine = filter (/= '\n') (expandTabs 8 0 srcLineWithNewline)

        start = srcSpanStartCol span - 1
        end | multiline = length srcLine
            | otherwise = srcSpanEndCol span - 1
        width = max 1 (end - start)

        marginWidth = length rowStr
        marginSpace = replicate marginWidth ' ' ++ " |"
        marginRow   = rowStr ++ " |"

        (srcLinePre,  srcLineRest) = splitAt start srcLine
        (srcLineSpan, srcLinePost) = splitAt width srcLineRest

        caretEllipsis | multiline = "..."
                      | otherwise = ""
        caretLine = replicate start ' ' ++ replicate width '^' ++ caretEllipsis

--
-- Queries
--

{- Note [Intrinsic And Extrinsic Failures]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We distinguish between /intrinsic/ and /extrinsic/ failures. We classify in
the former category those diagnostics which are /essentially/ failures, and
their nature can't be changed. This is the case for 'ErrorWithoutFlag'. We
classify as /extrinsic/ all those diagnostics (like fatal warnings) which are
born as warnings but which are still failures under particular 'DynFlags'
settings. It's important to be aware of such logic distinction, because when
we are inside the typechecker or the desugarer, we are interested about
intrinsic errors, and to bail out as soon as we find one of them. Conversely,
if we find an /extrinsic/ one, for example because a particular 'WarningFlag'
makes a warning into an error, we /don't/ want to bail out, that's still not the
right time to do so: Rather, we want to first collect all the diagnostics, and
later classify and report them appropriately (in the driver).
-}

-- | Returns 'True' if this is, intrinsically, a failure. See
-- Note [Intrinsic And Extrinsic Failures].
isIntrinsicErrorMessage :: Diagnostic e => MsgEnvelope e -> Bool
isIntrinsicErrorMessage = (==) ErrorWithoutFlag . diagnosticReason . errMsgDiagnostic

isWarningMessage :: Diagnostic e => MsgEnvelope e -> Bool
isWarningMessage = not . isIntrinsicErrorMessage

-- | Are there any hard errors here? -Werror warnings are /not/ detected. If
-- you want to check for -Werror warnings, use 'errorsOrFatalWarningsFound'.
errorsFound :: Diagnostic e => Messages e -> Bool
errorsFound (Messages msgs) = any isIntrinsicErrorMessage msgs

-- | Returns 'True' if the envelope contains a message that will stop
-- compilation: either an intrinsic error or a fatal (-Werror) warning
isExtrinsicErrorMessage :: MsgEnvelope e -> Bool
isExtrinsicErrorMessage = (==) SevError . errMsgSeverity

-- | Are there any errors or -Werror warnings here?
errorsOrFatalWarningsFound :: Messages e -> Bool
errorsOrFatalWarningsFound (Messages msgs) = any isExtrinsicErrorMessage msgs

getWarningMessages :: Diagnostic e => Messages e -> Bag (MsgEnvelope e)
getWarningMessages (Messages xs) = fst $ partitionBag isWarningMessage xs

getErrorMessages :: Diagnostic e => Messages e -> Bag (MsgEnvelope e)
getErrorMessages (Messages xs) = fst $ partitionBag isIntrinsicErrorMessage xs

-- | Partitions the 'Messages' and returns a tuple which first element are the
-- warnings, and the second the errors.
partitionMessages :: Diagnostic e => Messages e -> (Messages e, Messages e)
partitionMessages (Messages xs) = bimap Messages Messages (partitionBag isWarningMessage xs)

----------------------------------------------------------------
--                                                            --
-- Definition of diagnostic codes                             --
--                                                            --
----------------------------------------------------------------

-- | A diagnostic code is a namespaced numeric identifier
-- unique to the given diagnostic (error or warning).
--
-- All diagnostic codes defined within GHC are given the
-- GHC namespace.
--
-- See Note [Diagnostic codes] in GHC.Types.Error.Codes.
data DiagnosticCode =
  DiagnosticCode
    { diagnosticCodeNameSpace :: String
        -- ^ diagnostic code prefix (e.g. "GHC")
    , diagnosticCodeNumber    :: Natural
        -- ^ the actual diagnostic code
    }

instance Outputable DiagnosticCode where
  ppr (DiagnosticCode prefix c) =
    text prefix <> text "-" <> text (printf "%05d" c)
      -- pad the numeric code to have at least 5 digits
