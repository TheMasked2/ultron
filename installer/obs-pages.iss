{ OBS scene and audio track pages for the "Set up OBS" step. Shared by the Jarvis and
  OBS Game Watcher installers: keep the copies identical. Needs obs-setup.ps1 in [Files]
  (it's run early, from the temp folder, to list the existing scenes).
  Build with /DUiTest to get an installer that shows the pages but never installs. }
var
  ScenePage, TrackPage: TWizardPage;
  SceneCombo, TrackCountCombo: TNewComboBox;
  SceneNameEdit: TNewEdit;
  SceneNameLabel: TNewStaticText;
  TrackList: TNewCheckListBox;
  ScenesListed: Boolean;

const
  TrSimple = 0; TrEditing = 1; TrDiscord = 2; TrMusic = 3; TrFull = 4; TrCustom = 5; TrKeep = 6;

function ObsLabel(Page: TWizardPage; Caption: String; Left, Top: Integer; Gray: Boolean): TNewStaticText;
begin
  Result := TNewStaticText.Create(Page);
  Result.Parent := Page.Surface;
  Result.Caption := Caption;
  Result.Left := ScaleX(Left);
  Result.Top := ScaleY(Top);
  Result.Width := Page.SurfaceWidth - ScaleX(Left);
  Result.WordWrap := True;
  if Gray then Result.Font.Color := clGray;
end;

function ObsCombo(Page: TWizardPage; Left, Top, Width: Integer): TNewComboBox;
begin
  Result := TNewComboBox.Create(Page);
  Result.Parent := Page.Surface;
  Result.Style := csDropDownList;
  Result.Left := ScaleX(Left);
  Result.Top := ScaleY(Top);
  Result.Width := ScaleX(Width);
end;

procedure ObsPagesUpdate(Sender: TObject);
begin
  SceneNameEdit.Enabled := SceneCombo.ItemIndex = 0;
  SceneNameLabel.Enabled := SceneNameEdit.Enabled;
  TrackCountCombo.Enabled := TrackList.Checked[TrCustom];
end;

procedure CreateObsPages(AfterID: Integer);
var
  I: Integer;
begin
  { Dropdowns and a check list instead of loose radio buttons: a radio button that gets
    the keyboard focus selects itself, which changed the choice behind the user's back. }
  ScenePage := CreateCustomPage(AfterID, 'OBS scene', 'Which scene should show your game?');
  ObsLabel(ScenePage, 'Add the game sources to:', 0, 0, False);
  SceneCombo := ObsCombo(ScenePage, 0, 18, 300);
  SceneCombo.Items.Add('A new scene (recommended)');
  SceneCombo.ItemIndex := 0;
  SceneCombo.OnChange := @ObsPagesUpdate;
  SceneNameLabel := ObsLabel(ScenePage, 'Name of the new scene:', 0, 56, False);
  SceneNameEdit := TNewEdit.Create(ScenePage);
  SceneNameEdit.Parent := ScenePage.Surface;
  SceneNameEdit.Top := ScaleY(74);
  SceneNameEdit.Width := ScaleX(300);
  SceneNameEdit.Text := 'Game';
  ObsLabel(ScenePage, 'The Game Capture, Game Window and Game Audio sources are added to this scene, ' +
    'and OBS switches to it. Your other scenes stay as they are. If a scene with this name exists, it is used.', 0, 112, True);

  TrackPage := CreateCustomPage(ScenePage.ID, 'Audio tracks', 'Should clips keep sounds on separate tracks?');
  ObsLabel(TrackPage, 'Track 1 always has everything mixed, so clips sound right anywhere. ' +
    'Extra tracks let a video editor change the game, your mic or Discord separately.', 0, 0, True);
  TrackList := TNewCheckListBox.Create(TrackPage);
  TrackList.Parent := TrackPage.Surface;
  TrackList.Top := ScaleY(36);
  TrackList.Width := TrackPage.SurfaceWidth;
  TrackList.Height := ScaleY(158);
  TrackList.Flat := True;
  TrackList.BorderStyle := bsNone;
  TrackList.ParentColor := True;
  TrackList.MinItemHeight := ScaleY(22);
  TrackList.ShowLines := False;
  TrackList.WantTabs := True;
  TrackList.AddRadioButton('One track: everything mixed together', 'just sharing clips', 0, False, True, nil);
  TrackList.AddRadioButton('Separate tracks: 1 everything (all PC sound), 2 your mic, 3 game', 'recommended', 0, True, True, nil);
  TrackList.AddCheckBox('Discord voice chat on track 4', '', 1, True, True, False, True, nil);
  TrackList.AddCheckBox('Music player (Spotify and others) on track 5', '', 1, True, True, False, True, nil);
  TrackList.AddRadioButton('Each app separate: 2 mic, 3 game, 4 Discord, 5 music, 6 browser', 'only these apps', 0, False, True, nil);
  TrackList.AddRadioButton('Custom number of tracks (you choose what goes on them in OBS)', '', 0, False, True, nil);
  TrackList.AddRadioButton('Keep my current OBS audio settings', '', 0, False, True, nil);
  TrackList.OnClickCheck := @ObsPagesUpdate;
  ObsLabel(TrackPage, 'Number of tracks for Custom:', 0, 200, False);
  TrackCountCombo := ObsCombo(TrackPage, 170, 197, 50);
  for I := 1 to 6 do TrackCountCombo.Items.Add(IntToStr(I));
  TrackCountCombo.ItemIndex := 2;
  ObsLabel(TrackPage, '"Each app separate" skips Desktop Audio, so a program it doesn''t know (like a game you''re making) isn''t heard. "Separate tracks" catches every sound.', 0, 226, True);
  ObsPagesUpdate(nil);
end;

procedure ListObsScenes;
var
  Output: TExecOutput;
  Code, I: Integer;
  Line: String;
begin
  ScenesListed := True;
  try
    ExtractTemporaryFile('obs-setup.ps1');
    if ExecAndCaptureOutput(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\obs-setup.ps1') + '" -ListScenes',
      ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, Code, Output) then
      for I := 0 to GetArrayLength(Output.StdOut) - 1 do
      begin
        Line := Output.StdOut[I];
        if Pos('scene:', Line) = 1 then SceneCombo.Items.Add(Copy(Line, 7, Length(Line)));
      end;
  except
  end;
end;

procedure ObsPagesActivate(CurPageID: Integer);
begin
  if (CurPageID = ScenePage.ID) and not ScenesListed then ListObsScenes;
end;

function ObsPagesSkip(PageID: Integer): Boolean;
begin
  Result := ((PageID = ScenePage.ID) or (PageID = TrackPage.ID)) and not WizardIsTaskSelected('obs');
end;

function ObsPagesNext(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = ScenePage.ID) and (SceneCombo.ItemIndex = 0) and
     ((Trim(SceneNameEdit.Text) = '') or (Pos('"', SceneNameEdit.Text) > 0)) then
  begin
    MsgBox('Enter a name for the new scene, for example Game.', mbError, MB_OK);
    Result := False;
  end;
end;

{ Arguments for obs-setup.ps1 from the two pages. }
function ObsPagesParams: String;
var
  Scene: String;
begin
  if SceneCombo.ItemIndex = 0 then Scene := Trim(SceneNameEdit.Text) else Scene := SceneCombo.Text;
  Result := ' -Scene "' + Scene + '"';
  if TrackList.Checked[TrSimple] then Result := Result + ' -Tracks Simple'
  else if TrackList.Checked[TrEditing] then
  begin
    Result := Result + ' -Tracks Editing';
    if TrackList.Checked[TrDiscord] then Result := Result + ' -DiscordTrack';
    if TrackList.Checked[TrMusic] then Result := Result + ' -MusicTrack';
  end
  else if TrackList.Checked[TrFull] then Result := Result + ' -Tracks Full'
  else if TrackList.Checked[TrCustom] then Result := Result + ' -Tracks Custom -TrackCount ' + IntToStr(TrackCountCombo.ItemIndex + 1)
  else Result := Result + ' -Tracks Keep';
end;

{ The UiTest build stops here, before anything is installed. Returns '' otherwise. }
function ObsPagesTestStop: String;
begin
  Result := '';
#ifdef UiTest
  Result := 'UI test build: nothing is installed. Would run obs-setup.ps1 with:' + ObsPagesParams;
#endif
end;

{ "Ready to Install" page: spell out the OBS choices, so they can be checked before Install. }
function ObsPagesSummary(NewLine, Space: String): String;
begin
  Result := '';
  if not WizardIsTaskSelected('obs') then Exit;
  Result := 'OBS:' + NewLine + Space;
  if SceneCombo.ItemIndex = 0 then Result := Result + 'Scene: new scene "' + Trim(SceneNameEdit.Text) + '"'
  else Result := Result + 'Scene: "' + SceneCombo.Text + '"';
  Result := Result + NewLine + Space + 'Audio: ';
  if TrackList.Checked[TrSimple] then Result := Result + 'one track, everything mixed'
  else if TrackList.Checked[TrEditing] then
  begin
    Result := Result + '1 everything, 2 mic, 3 game';
    if TrackList.Checked[TrDiscord] then Result := Result + ', 4 Discord';
    if TrackList.Checked[TrMusic] then Result := Result + ', 5 music';
  end
  else if TrackList.Checked[TrFull] then Result := Result + '1 everything, 2 mic, 3 game, 4 Discord, 5 music, 6 browser (Desktop Audio muted: other programs are not recorded)'
  else if TrackList.Checked[TrCustom] then Result := Result + IntToStr(TrackCountCombo.ItemIndex + 1) + ' tracks (set up in OBS)'
  else Result := Result + 'keep current settings';
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := MemoDirInfo + NewLine + NewLine + MemoTasksInfo;
  if WizardIsTaskSelected('obs') then Result := Result + NewLine + NewLine + ObsPagesSummary(NewLine, Space);
end;
