unit YouTubeApi;

interface

uses
  IdHTTP, System.Classes, System.Generics.Collections, FMX.Graphics;

type
  TYouTubeID = String;

  TYouTubeObjectState = (ytsNotExists, ytsNotLoaded, ytsNavigating, ytsLoadError ,
    ytsInvalidYoutube, ytsValidNoThumb, ytsValid);

  TYouTubeInfo = class(TObject)
  private
    type
      TYouTubeDictionary = TObjectDictionary<TYouTubeID,TYouTubeInfo>;
      TYouTubeQueue = TQueue<TYouTubeInfo>;
    class var FQueue: TYouTubeQueue;            // queue of TYouTubeInfo to load
    class var FDictionary: TYouTubeDictionary;  // contains all created TYouTubeInfo objects
    class var FRunningThreads: Cardinal;        // number of running threads
  private
    FHTTP: TIdHTTP;
    FThread: TThread;
    FVideoDuration:  String;
    FCanonicalURL:   String;
    FSmallImageURL:  String;
    FNormalImageURL: String;
    FSourceCode:  String;
    FVID:         String;
    FTitle:       String;
    FURL:         String;
    FBigImageURL: String;
    FChannelID:   String;
    FEmbedURL:    String;
    FDescription: String;
    FErrorMessage: String;
    FVideoID:     TYouTubeID;
    FVideoWidth:  Integer;
    FVideoHeight: Integer;
    FTryCount:    Cardinal;
    FState:       TYouTubeObjectState;
    FThumbnail:   TBitmap;
    class constructor Create;
    class destructor Destroy;
    class function GetItem(const AVID: String): TYouTubeInfo; static;
    class function GetItemState(const AVID: String): TYouTubeObjectState; static;
    function GetHTTP: TIdHTTP;
    property idHTTP: TIdHTTP read GetHTTP;
    function GetThumbnail: TBitmap;
    function GetVideoID: String; inline;
    function GetTitle: String; inline;
    function GetVideoWidth: Integer;  inline;
    function GetVideoHeight: Integer; inline;
    function GetSmallImageURL: String; inline;
    function GetNormalImageURL: String; inline;
    function GetBigImageURL: String; inline;
    function GetChannelID: String; inline;
    function GetEmbedURL: String; inline;
    function GetDescription: String; inline;
    function GetVideoDuration: String; inline;
    function GetCanonicalURL: String; inline;
    procedure ParseSourceCode;
    procedure SetToDefault;
    function Navigate: Boolean;
    function DoNavigateAsync: Boolean;
    procedure OnThreadTerminate(Sender: TObject);
    class function Parse(Source, Left, Right: String): String; static;
  public
    type
      TYouTubeNotifyEvent = procedure(const AItem: TYouTubeInfo) of object;
  public
    class var MaxRunningThreads: Word;
    class var OnNotify: TYouTubeNotifyEvent;    // for notification of ending retrival, should store data in our database
    class property Items[const AVID: String]: TYouTubeInfo read GetItem; default;
    class property ItemState[const AVID: String]: TYouTubeObjectState read GetItemState;
    class function ContainsItem(const AVID: String): Boolean; static;
    // recommended method for adding URL to navigate
    class function NavigateItem(const AVID, AURL: String; AUrgent: Boolean = False): TYouTubeInfo; static;
    class function IsYoutube(const AURL: String): Boolean; static; // Check if URL is youtube URL
    function CreateThumbnail(const AWidth, AHeight: Integer): TBitmap;
    function NavigateAsync(const AURL: String = ''; AUrgent: Boolean = False): Boolean; // Empty URL for next try
    function StateAsString: String;                      // for debug
    property State: TYouTubeObjectState read FState;
    property VideoID: TYouTubeID read FVideoID;
    property Title: String read FTitle;
    property VideoWidth: Integer read FVideoWidth;
    property VideoHeight: Integer read FVideoHeight;
    property Thumbnail: TBitmap read FThumbnail;         // Usially small image (default.jpg)
    property ChannelID: String read FChannelID;
    property EmbedURL: String read FEmbedURL;            // URL for player
    property Description: String read FDescription;
    property VideoDuration: String read FVideoDuration;
    property CanonicalURL: String read FCanonicalURL;
    property URL: String read FURL;                      // = mmvurl loading URL
    property VID: String read FVID;                      // = mmvid I think VID usially the same as VideoID
    property Thread: TThread read FThread;
    property TryCount: Cardinal read FTryCount;          // how much we tried to load this URL
    property ErrorMessage: String read FErrorMessage;
    function GetInfo(ALog: TStrings): Boolean;           // for debug log
    constructor Create(const AVID: String); overload;
    constructor Create(const AVID, AURL: string); overload;
    destructor  Destroy; override;
  end;

implementation

uses
  SysUtils, RegularExpressions;

{ TYouTubeInfo }

constructor TYouTubeInfo.Create(const AVID: String);
begin
  FVID:= AVID;
  FURL:= EmptyStr;
  FHTTP := nil;
  FThumbnail := nil;
  FThread := nil;
  FTryCount:= 0;
  SetToDefault;
  FDictionary.Add(AVID,Self);
end;

constructor TYouTubeInfo.Create(const AVID, AURL: string);
begin
  Create(AVID);
  NavigateAsync(AURL);
end;

function TYouTubeInfo.CreateThumbnail(const AWidth, AHeight: Integer): TBitmap;
begin
  Result:= Thumbnail.CreateThumbnail(AWidth,AHeight);
end;

procedure TYouTubeInfo.OnThreadTerminate(Sender: TObject);
begin
  FThread := nil;
  dec(FRunningThreads);
  if ((MaxRunningThreads = 0) or (FRunningThreads < MaxRunningThreads)) and (FQueue.Count > 0) then
    FQueue.Dequeue.DoNavigateAsync;
  if Assigned(OnNotify) then
    OnNotify(Self);
end;

class constructor TYouTubeInfo.Create;
begin
  FRunningThreads := 0;
  MaxRunningThreads := 3;
  OnNotify := nil;
  FDictionary := TYouTubeDictionary.Create([doOwnsValues]);
  FQueue := TYouTubeQueue.Create;
end;

class destructor TYouTubeInfo.Destroy;
begin
  FQueue.Free;
  FDictionary.Free;
  inherited;
end;

destructor TYouTubeInfo.Destroy;
begin
  if FHTTP <> nil then
    FreeAndNil(FHTTP);
  if FThumbnail <> nil  then
    FreeAndNil(FThumbnail);
  inherited;
end;

function TYouTubeInfo.DoNavigateAsync: Boolean;
begin
  Result := False;
  if FThread <> nil then
    Exit;
  FThread := TThread.CreateAnonymousThread(
    procedure
    begin
       Navigate;
    end);
  if FThread = nil then
    Exit;
  Result := True;
  inc(FTryCount);
  FThread.OnTerminate := OnThreadTerminate;
  FThread.Start;
  inc(FRunningThreads);
end;

class function TYouTubeInfo.Parse(Source, Left, Right: String): String;
var LLeftPosition,LRightPosition: Integer;
begin
  Result := EmptyStr;
  LLeftPosition := Pos(Left, Source);
  if LLeftPosition <= 0 then
    Exit;
  Delete(Source, 1, LLeftPosition + Length(Left) - 1);
  LRightPosition := Pos(Right, Source);
  if LRightPosition <= 0 then
    Exit;
  Result := Copy(Source, 1, LRightPosition - 1);
end;


procedure TYouTubeInfo.ParseSourceCode;
begin
  FState:= ytsInvalidYoutube;
  if FSourceCode = EmptyStr then
    Exit;
  try
    FVideoWidth:= GetVideoWidth;
    FVideoHeight:= GetVideoHeight;
    FVideoID:= GetVideoID;
    FTitle:= GetTitle;
    FEmbedURL:= GetEmbedURL;
    FSmallImageURL:= GetSmallImageURL;
    FNormalImageURL:= GetNormalImageURL;
    FBigImageURL:= GetBigImageURL;
    FChannelID:= GetChannelID;
    FDescription:= GetDescription;
    FVideoDuration:= GetVideoDuration;
    FCanonicalURL:= GetCanonicalURL;
    if Length(VideoID) > 0 then
      FState:= TYouTubeObjectState.ytsValidNoThumb;
    if Assigned(FThumbnail) then
      FreeAndNil(FThumbnail);
    FThumbnail := GetThumbnail;
    if Assigned(FThumbnail) and not FThumbnail.IsEmpty then
      FState:= TYouTubeObjectState.ytsValid;
  except
    on E: Exception do
      FErrorMessage := E.ClassName+': ' +E.ToString;
  end;
end;

procedure TYouTubeInfo.SetToDefault;
begin
  FURL := EmptyStr;
  FState:= TYouTubeObjectState.ytsNotLoaded;
  FSourceCode := EmptyStr;
  FVideoID:= EmptyStr;
  FTitle:= EmptyStr;
  FVideoWidth:= 0;
  FVideoHeight:= 0;
  FSmallImageURL:= EmptyStr;
  FNormalImageURL:= EmptyStr;
  FBigImageURL:= EmptyStr;
  FChannelID:= EmptyStr;
  FEmbedURL:= EmptyStr;
  FDescription:= EmptyStr;
  FVideoDuration:= EmptyStr;
  FCanonicalURL:= EmptyStr;
  FErrorMessage := EmptyStr;
  if FThumbnail <> nil  then
    FreeAndNil(FThumbnail);
end;

function TYouTubeInfo.Navigate: Boolean;
begin
  Result:= False;
  if State = ytsNavigating then
    Exit;
  SetToDefault;
  if FURL = EmptyStr then
    Exit;
  FState := ytsNavigating;
  try
  idHTTP.Request.Accept := 'text/html';
    FSourceCode := idHTTP.Get(StringReplace(FURL, 'https://', 'http://', [rfReplaceAll, rfIgnoreCase]));
  except
    on E: Exception do 
    begin
      FState:= ytsLoadError;
      FErrorMessage := E.ClassName+': ' +E.ToString;
      Exit;
    end;
  end;
  ParseSourceCode;
  Result := FState = ytsValid;
  if Result then  // FHTTP and FSourceCode are no longer needed
  begin
    if Assigned(FHTTP) then
      FreeAndNil(FHTTP);
    FSourceCode := EmptyStr;
  end;
end;

function TYouTubeInfo.NavigateAsync(const AURL: String = ''; AUrgent: Boolean = False): Boolean;
begin
  Result:= False;
  if State = ytsNavigating then Exit;
  if AURL <> EmptyStr then
    FURL := AURL;
  if FURL = EmptyStr then
    Exit;
  if AUrgent or (MaxRunningThreads=0) or (FRunningThreads < MaxRunningThreads) then
    Result := DoNavigateAsync
  else
    FQueue.Enqueue(Self);
end;

class function TYouTubeInfo.NavigateItem(const AVID, AURL: String; AUrgent: Boolean = False): TYouTubeInfo;
begin
  Result := TYouTubeInfo.Create(AVID);
  Result.NavigateAsync(AURL, AUrgent);
end;

const
  ogVideoMatch=     '(?<=<meta property="og:video" content=")(http[s]?:\/\/(www\.)?youtube.com[\w/\-?=&;]*?)(?=">)';
  ogImageMatch=     '(?<=<meta property="og:image" content=")(.*?)(?=">)';
  ogTitleMatch=     '(?<=<meta property="og:title" content=")(.*?)(?=">)';
  ogVideoIDMatch=   '(?<=<meta itemprop="videoId" content=")(.*?)(?=">)';
  ogWidthMatch=     '(?<=<meta itemprop="width" content=")(.*?)(?=">)';
  ogHeightMatch=    '(?<=<meta itemprop="height" content=")(.*?)(?=">)';
  ogEmbebMatch=     '(?<=<link itemprop="embedURL" href=")(.*?)(?=">)';
  ogThumbnailMatch= '(?<=<link itemprop="thumbnailUrl" href=")(.*?)(?=">)';
  ogAnyYoutubeURLMatch='^((http[s]?|android-app|vnd.youtube):(\/){2})?(([\w-]+?\.)*?(youtu.be|youtube\.[\w-]+?)|([\w-]+?\.)*?[\w-]+?\.youtube)\.?(\/?$|\/[\w-?=&;/%.]*)$';
  ogYoutubeURLMatch='^((http[s]?):(\/){2})?(([\w-]+?\.)*?(youtu.be|youtube\.[\w-]+?)|([\w-]+?\.)*?[\w-]+?\.youtube)\.?(\/?$|\/[\w-?=&;/%.]*)$';

function TYouTubeInfo.GetVideoID: String;
begin
  Result := Trim(Parse(FSourceCode, 'videoId" content="', '">'));
end;

function TYouTubeInfo.GetThumbnail: TBitmap;
var
  LImageStream: TBytesStream;
begin
  Result := nil;
  LImageStream := nil;
  if State = ytsNotLoaded then Exit;
  if FSmallImageURL = EmptyStr then Exit;
  idHTTP.Request.Accept := 'image/*';
  LImageStream := TBytesStream.Create;
  try
    idHTTP.Get(FSmallImageURL, LImageStream);
    if LImageStream.Size > 0 then
    begin
      LImageStream.Position := 0; // important!
      Result := TBitmap.CreateFromStream(LImageStream);
    end;
  except
    on E: Exception do
      FErrorMessage := E.ClassName+': ' +E.ToString;
  end;
  LImageStream.Free;
end;

function TYouTubeInfo.GetTitle: String;
var
  X: String;
begin
  X := Parse(FSourceCode, 'og:title" content="', '">');
  X := StringReplace(X, '&quot;', '"', [rfReplaceAll, rfIgnoreCase]);
  X := StringReplace(X, '&#39;', '''', [rfReplaceAll, rfIgnoreCase]);
  X := StringReplace(X, '&lt;', '(', [rfReplaceAll, rfIgnoreCase]);
  X := StringReplace(X, '&gt;', ')', [rfReplaceAll, rfIgnoreCase]);
  X := StringReplace(X, '+', ' ', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(X, 'amp;', '', [rfReplaceAll, rfIgnoreCase]);
end;

function TYouTubeInfo.GetVideoWidth: Integer;
begin
  try
    Result := StrToInt(Trim(Parse(FSourceCode, 'og:video:width" content="', '">')));
  except
    Result := 0;
  end;
end;

function TYouTubeInfo.GetInfo(ALog: TStrings): Boolean;
begin
  Result:= State = TYouTubeObjectState.ytsValid;
  with ALog do
  begin
    Append('');
    Append('State: ' + StateAsString);
    Append('URL: '+URL);
    Append('Threads: ' + IntToStr(FRunningThreads));
    if Result or (State = TYouTubeObjectState.ytsValidNoThumb) then
    begin
      Append('VideoID: '+VideoID);
      Append('Title: '+Title);
      ALog.Append('Canonical URL: '+CanonicalURL);
      Append('Embed URL: '+EmbedURL);
      Append('Video Width: '+IntToStr(VideoWidth));
      Append('Video Height: '+IntToStr(VideoHeight));
      Append('Small Image URL: '+FSmallImageURL);
      Append('Normal Image URL: '+FNormalImageURL);
      Append('Big Image URL: '+FBigImageURL);
      Append('Channel ID: '+ChannelID);
      Append('Description: '+Description);
      Append('Video Duration: '+VideoDuration);
    end;
  end;
end;

class function TYouTubeInfo.GetItem(const AVID: String): TYouTubeInfo;
begin
  Result := FDictionary[AVID];
end;

class function TYouTubeInfo.ContainsItem(const AVID: String): Boolean;
begin
  Result := FDictionary.ContainsKey(AVID);
end;

function TYouTubeInfo.GetVideoHeight: Integer;
begin
  try
    Result := StrToInt(Trim(Parse(FSourceCode, 'og:video:height" content="', '">')));
  except
    Result := 0;
  end;
end;

function TYouTubeInfo.GetSmallImageURL: String;
var
  X: String;
begin
  X := GetBigImageURL;
  X:= StringReplace(X, 'hqdefault.jpg', 'default.jpg', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(X, 'maxresdefault.jpg', 'default.jpg', [rfReplaceAll, rfIgnoreCase]);
//  Result := X;
end;

function TYouTubeInfo.StateAsString: String;
const
  YouTubeObjectStates: array[TYouTubeObjectState] of String = (
    'Not Exists', 'Not Loaded', 'Navigating', 'Load Error ', 'Invalid Youtube URL', 'Valid but no thumb loaded', 'Valid');
begin
  Result := YouTubeObjectStates[State];
end;

class function TYouTubeInfo.GetItemState(const AVID: String): TYouTubeObjectState;
begin
  Result := Items[AVID].State;
end;

function TYouTubeInfo.GetNormalImageURL: String;
var
  X: String;
begin
  X := GetBigImageURL;
  Result := StringReplace(X, 'hqdefault.jpg', 'mqdefault.jpg', [rfReplaceAll, rfIgnoreCase]);
end;

function TYouTubeInfo.GetBigImageURL: String;
begin
  Result := Parse(FSourceCode, 'og:image" content="', '">');
end;

function TYouTubeInfo.GetCanonicalURL: String;
begin
  Result := Trim(Parse(FSourceCode, 'canonical" href="', '">'));
end;

function TYouTubeInfo.GetChannelID: String;
begin
  Result := Trim(Parse(FSourceCode, 'channelId" content="', '">'));
end;

function TYouTubeInfo.GetEmbedURL: String;
var
  X: String;
begin
  X := Parse(FSourceCode, 'embedURL" href="', '">');
  X := StringReplace(X, 'https://', 'http://', [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(X, 'amp;', '', [rfReplaceAll, rfIgnoreCase])+'?autoplay=1'; // #t=0 start from 0
end;

function TYouTubeInfo.GetHTTP: TIdHTTP;
begin
  if FHTTP = nil then
  begin
    FHTTP := TIdHTTP.Create;
  end;
  Result := FHTTP;
end;

function TYouTubeInfo.GetDescription: String;
begin
  Result := Parse(FSourceCode, 'og:description" content="', '">');
end;

function TYouTubeInfo.GetVideoDuration: String;
var
  X: String;
begin
  X := Parse(FSourceCode, 'duration" content="', '">');
  X := StringReplace(X, 'PT', '', [rfReplaceAll, rfIgnoreCase]);
  X := StringReplace(X, 'M', ':', [rfReplaceAll, rfIgnoreCase]);
  X := StringReplace(X, 'S', '', [rfReplaceAll, rfIgnoreCase]);
  Result := X;
end;

// Check if URL is youtube URL
class function TYouTubeInfo.IsYoutube(const AURL: String): Boolean;
const
  ogAllYoutubeURLMatch='^((http[s]?|android-app|vnd.youtube):(\/){2})?(([\w-]+?\.)*?(youtu.be|youtube\.[\w-]+?)|([\w-]+?\.)*?[\w-]+?\.youtube)\.?(\/?$|\/[\w-?=&;/%.]*)$';
  ogYoutubeURLMatch='^((http[s]?):(\/){2})?(([\w-]+?\.)*?(youtu.be|youtube\.[\w-]+?)|([\w-]+?\.)*?[\w-]+?\.youtube)\.?(\/?$|\/[\w-?=&;/%.]*)$';
begin
  Result:= TRegEx.IsMatch(AURL,ogYoutubeURLMatch, [roIgnoreCase]);
end;

{
const
  bmmtitle    = 1;
  bmmvideourl = 2;
  bmmimgurl   = 4;
  bmmimg      = 8;
  bmmAll      = 15;

function bIsLoaded(AParam, Abit: Integer): Boolean; inline;
begin
  Result := (Aparam and Abit) = Abit;
end;
}

end.
