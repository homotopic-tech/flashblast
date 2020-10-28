{-# LANGUAGE DuplicateRecordFields #-}

import           Colog.Polysemy
import           Colog.Polysemy.Formatting
import           Colog.Polysemy.Formatting.Color
import           Colog.Polysemy.Formatting.LogEnv
import           Colog.Polysemy.Formatting.Render
import           Colog.Polysemy.Formatting.ThreadTimeMessage
import           Composite.Record
import qualified Data.Attoparsec.Text                        as A
import           Data.Monoid.Generic
import           Data.Text.Lazy.Builder                      (Builder)
import qualified Dhall                                       as D
import           FlashBlast.Domain
import           Network.HTTP.Simple
import           Path
import           Path.Dhall                                  ()
import           Path.Utils
import           Polysemy
import           Polysemy.Error                              as P
import           Polysemy.Input
import           Polysemy.KVStore
import           Polysemy.Output
import           Polysemy.Several
import           Polysemy.Video                              hiding (to)
import           RIO.Time

import           FlashBlast.ClozeParse
import qualified FlashBlast.Config                           as Config
import           FlashBlast.Conventions
import           FlashBlast.ForvoClient                      hiding (id)
import           FlashBlast.FS
import           FlashBlast.JSONFileStore
import           FlashBlast.KVStore
import           FlashBlast.YouTubeDL
import qualified Formatting                                  as F
import           Formatting.Time
import           Optics
import           Polysemy.Methodology
import           Polysemy.State
import           Polysemy.Tagged
import           RIO                                         hiding (Builder,
                                                              logInfo, over, to,
                                                              view,
                                                              writeFileUtf8,
                                                              (^.))
import           RIO.List
import qualified RIO.Map                                     as Map
import qualified RIO.Text                                    as T
import qualified Text.Subtitles.SRT                          as SR

fromTime :: SR.Time -> Time
fromTime (SR.Time h m s f) = Time h m s f

fromRange :: SR.Range -> Range
fromRange (SR.Range f t) = Range (fromTime f) (fromTime t)

fFieldsGreenBarSep :: UseColor -> F.Format r ([Builder] -> r)
fFieldsGreenBarSep useColor = F.later $ \fields ->
  let withFG = getWithFG useColor
      sep = F.format F.builder $ withFG Green " | "
  in F.bformat (F.intercalated sep F.builder) fields

interpretVideoSource :: Members '[Input Config.ResourceDirs, YouTubeDL] m
                     => Config.VideoSource
                     -> Sem m (Path Rel File)
interpretVideoSource = \case
  Config.YouTubeDL (Config.YDLInfo x y f) -> do
    Config.ResourceDirs{..} <- input @Config.ResourceDirs
    youTubeDL' x (_video </> y) f
    return (_video </> y)
  Config.LocalVideo x -> do
    Config.ResourceDirs{..} <- input @Config.ResourceDirs
    return (_video </> x)

runExcerptSpecIO :: Members '[ Error SubtitleParseException
                             , FSExist
                             , FSTemp
                             , FSCopy
                             , FSDir
                             , Input Config.ExportDirs
                             , Input Config.ResourceDirs
                             , YouTubeDL
                             , ClipProcess] m
                 => Config.ExcerptSpec
                 -> Sem m [RExcerptNote]
runExcerptSpecIO Config.ExcerptSpec {..} = do
  Config.ExportDirs{..} <- input @Config.ExportDirs
  t <- interpretVideoSource _source
  s' <- either (throw . SubtitleParseException) return $ A.parseOnly SR.parseSRT _subs
  let cs = map (_clipf  . T.pack . show . SR.index) s'
  let es = map (_audiof . T.pack . show . SR.index) s'
  let fs = map (_framef . T.pack . show . SR.index) s'
  cs' <- filterM (fmap not . doesFileExist . (_clips </>)) cs
  es' <- filterM (fmap not . doesFileExist . (_audio </>)) es
  h <- createTempDirectory
  createDirectory _clips
  createDirectory _audio
  createDirectory _images
  unless (null cs') $ do
    extractClips t $ zip (fromRange . SR.range <$> s') (h </$> cs')
    forM_ cs' $ \x -> copyFile (h </> x) (_clips </> x)
  unless (null es') $ do
    extractAudio t $ zip (fromRange . SR.range <$> s') (h </$> es)
    forM_ es' $ \x -> copyFile (h </> x) (_audio </> x)
  removeDirectory h
  forM (zip4 s' cs es fs) $ \(l, c, e, f) -> do
    whenM (fmap not . doesFileExist $ _images </> f) $
      extractFrames (_clips </> c) [(Time 0 0 0 0, _images </> f)]
    return $ val @"front" (fst . genClozePhrase . SR.dialog $ l)
          :& val @"extra" f
          :& val @"back"  e
          :& RNil

newtype SubtitleParseException = SubtitleParseException String
  deriving (Eq, Show, Generic)

instance Exception SubtitleParseException

downloadMP3For :: Members '[ForvoClient] r => Locale -> Text -> Sem r (Maybe ByteString)
downloadMP3For l@(Locale l') t = do
  ForvoStandardPronunciationResponseBody {..} <- standardPronunciation l t
  case items of
      []     -> return Nothing
      (x':_) -> Just <$> mP3For x'

getForvo :: Members '[ FSKVStore Rel
                     , ForvoClient] r
         => Locale -> Text -> Path Rel File -> Sem r ()
getForvo l t f = do
  z <- lookupKV f
  case z of
    Just _ -> return ()
    Nothing -> do
      x' <- downloadMP3For l t
      updateKV f x'

fIso8601 :: FormatTime a => (Color -> Builder -> Builder) -> F.Format r (a -> r)
fIso8601 withFG = F.later $ \time -> mconcat
  [ F.bformat dateDash time
  , withFG Green "T"
  , withFG Yellow $ F.bformat hms time
  ]

renderThreadTimeMessage' :: LogEnv -> ThreadTimeMessage -> T.Text
renderThreadTimeMessage' (LogEnv useColor zone) (ThreadTimeMessage threadId time (Msg severity stack message)) =
  let withFG = getWithFG useColor
  in F.sformat (fFieldsGreenBarSep useColor)
    [ F.bformat (fSeverity withFG) severity
    , F.bformat (fIso8601 withFG) (utcToZonedTime zone time)
    , F.bformat F.stext message
    ]


runMultiClozeSpecIO :: Members '[ Input Config.ResourceDirs
                                , FSWrite
                                , FSRead
                                , FSExist
                                , FSDir] m
                    => (Text -> Path Rel File)
                    -> Maybe Config.ForvoSpec
                    -> Config.MultiClozeSpec
                    -> Sem m [RForvoNote]
runMultiClozeSpecIO f s (Config.MultiClozeSpec p is) = do
    Config.ResourceDirs{..} <- input @Config.ResourceDirs
    forM p \a -> let (bs, cs) = genClozePhrase a
                 in return $ genForvos bs is (map f cs)

runPronunciationSpecIO :: Members '[Input Config.ResourceDirs
                                   , FSWrite
                                   , FSExist
                                   , FSRead
                                   , FSDir
                                   ] m
                        => Config.PronunciationSpec
                        -> Sem m [RForvoNote]
runPronunciationSpecIO (Config.PronunciationSpec f ms a) = do
                                                     zs <- forM ms $ runMultiClozeSpecIO f a
                                                     return $ join zs


runFSKVStoreRelIn :: Members '[FSExist, FSRead, FSWrite, FSDir] r => Path b Dir -> Sem (FSKVStore Rel ': r) a -> Sem r a
runFSKVStoreRelIn d = interpret \case
  LookupKV k   -> do
    createDirectory d
    z <- doesFileExist (d </> k)
    if z
      then fmap Just . readFileBS $ d </> k
      else return Nothing
  UpdateKV k v -> do
    createDirectory d
    case v of
      Nothing -> pure ()
      Just x  -> writeFileBS (d </> k) x

hotKVStore :: forall t t' k v r. Members '[Input k, Tagged t (KVStore k v), Tagged t' (KVStore k v)] r => Sem r ()
hotKVStore = do
  a <- input @k
  z <- tag @t @(KVStore k v) $ existsKV @k @v a
  if z
    then return ()
  else
    do
      x <- tag @t' @(KVStore k v) $ lookupKV @k @v a
      case x of
        Nothing -> return ()
        Just x' -> tag @t @(KVStore k v) $ writeKV @k @v a x'

runKVStoreAsKVStore :: forall k v k' v' r a. Getter k k' -> Iso' v v' -> Sem (KVStore k v ': r) a -> Sem (KVStore k' v' ': r) a
runKVStoreAsKVStore f g = reinterpret \case
  LookupKV k   -> fmap (review g) <$> lookupKV @k' @v' (view f k)
  UpdateKV k x -> updateKV @k' @v' (view f k) (fmap (view g) x)

data Deck = Deck {
  notes :: [Path Rel File]
, media :: [Path Rel File]
} deriving stock (Eq, Show, Generic)
  deriving Semigroup via GenericSemigroup Deck
  deriving Monoid via GenericMonoid Deck

generateMinimalReversedNoteVF :: Config.MinimalReversedCard -> RMinimalNoteVF
generateMinimalReversedNoteVF Config.MinimalReversedCard{..} = val @"front" _front
                                                            :& val @"back"  _back
                                                            :& RNil

generateBasicReversedNoteVF :: Config.BasicReversedCard -> RBasicReversedNoteVF
generateBasicReversedNoteVF Config.BasicReversedCard{..} = val @"front"       _front
                                                        :& val @"front-extra" _front_extra
                                                        :& val @"back"        _back
                                                        :& val @"back-extra"  _back_extra
                                                        :& RNil

extractParts :: Prism' Config.Spec x -> Config.Deck -> Map (Path Rel File) x
extractParts x = Map.fromList . itoListOf
                  ( Config.parts
                  % itraversed
                  %> reindexed (view Config.outfile) selfIndex
                  % Config.spec
                  % x
                  )

makeSubDeck' :: (Members '[Input Config.ExportDirs, FSWrite] r, RenderNote a) => (b -> Sem r [a]) -> Map (Path Rel File) [b] -> Sem r Deck
makeSubDeck' r x = do
  Config.ExportDirs{..} <- input @Config.ExportDirs
  (x' :: Map (Path Rel File) [a]) <- mapM (mapM r) x
  forM_ (Map.toList x') $ \(f, ks) ->
    writeFileUtf8 (_notes </> f) . T.intercalate "\n" $ (fmap renderNote =<< ks)
  return $ Deck (Map.keys x') []

type DeckSplit = '[Map (Path Rel File) [Config.MinimalReversedCard]
                 , Map (Path Rel File) [Config.BasicReversedCard]
                 , Map (Path Rel File) [Config.ExcerptSpec]
                 , Map (Path Rel File) [Config.PronunciationSpec]
                 ]

main :: IO ()
main = do
  Config.FlashBlast{..} <- D.input D.auto "./index.dhall"
  forM_ _decks $ \x -> do
    flashblast @Config.Deck @Deck
        & untag @DeckConfiguration
        & runInputConst x
        & untag @CollectionsPackage
        & runOutputSem (embed . traceShowM)
        & untag @ConstructionMethodology
        & decomposeMethodology @Config.Deck
                               @DeckSplit
                               @Deck
        & separateMethodologyInitial @Config.Deck @(Map (Path Rel File) [Config.MinimalReversedCard])
          & runMethodologyPure (extractParts Config._MinimalReversed)
        & separateMethodologyInitial @Config.Deck @(Map (Path Rel File) [Config.BasicReversedCard])
          & runMethodologyPure (extractParts Config._BasicReversed)
        & separateMethodologyInitial @Config.Deck @(Map (Path Rel File) [Config.ExcerptSpec])
          & runMethodologyPure (extractParts Config._Excerpt)
        & separateMethodologyInitial @Config.Deck @(Map (Path Rel File) [Config.PronunciationSpec])
          & runMethodologyPure (extractParts Config._Pronunciation)
        & endMethodologyInitial
        & separateMethodologyTerminal @(Map (Path Rel File) [Config.MinimalReversedCard]) @DeckSplit @Deck
          & runMethodologySem (makeSubDeck' $ pure . pure . generateMinimalReversedNoteVF)
        & separateMethodologyTerminal @(Map (Path Rel File) [Config.BasicReversedCard]) @DeckSplit @Deck
          & runMethodologySem (makeSubDeck' $ pure . pure . generateBasicReversedNoteVF)
        & separateMethodologyTerminal @(Map (Path Rel File) [Config.ExcerptSpec]) @DeckSplit @Deck
          & runMethodologySem (makeSubDeck' runExcerptSpecIO)
        & separateMethodologyTerminal @(Map (Path Rel File) [Config.PronunciationSpec]) @DeckSplit @Deck
          & runMethodologySem (makeSubDeck' runPronunciationSpecIO)
        & endMethodologyTerminal
        & runInputConst @Config.ExportDirs   (view Config.exportDirs x)
        & runInputConst @Config.ResourceDirs (view Config.resourceDirs x)
        & runFSWriteIO
        & runFSDirIO
        & runFSCopyIO
        & runFSExistIO
        & runFSTempIO
        & runFSReadIO
        & interpretYouTubeDL
        & runError @SubtitleParseException
        & runError @ForvoLimitReachedException
        & runRemoteHttpRequest
        & runError @ForvoResponseNotUnderstood
        & runError @ForvoAPIKeyIncorrectException
        & runError @JSONException
        & runError @BadRequestException
        & interpretFFMpegCli
        & runM
