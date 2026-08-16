{
  lib,
  flutter341,
  fetchFromGitHub,
  runCommand,
  nix-update-script,
  yq-go,
  _experimental-update-script-combinators,
}:

flutter341.buildFlutterApplication rec {
  pname = "convertall";
  version = "1.0.3";

  src = fetchFromGitHub {
    owner = "doug-101";
    repo = "ConvertAll";
    tag = "v${version}";
    hash = "sha256-f9HfLfxY2G/3rZoWJ1xLeGmkdFiIyUFkr65Jf8QMqjY=";
  };

  pubspecLock = lib.importJSON ./pubspec.lock.json;

  passthru = {
    pubspecSource =
      runCommand "pubspec.lock.json"
        {
          inherit src;
          nativeBuildInputs = [ yq-go ];
        }
        ''
          yq eval --output-format=json --prettyPrint $src/pubspec.lock > "$out"
        '';
    updateScript = _experimental-update-script-combinators.sequence [
      (nix-update-script { })
      (
        (_experimental-update-script-combinators.copyAttrOutputToFile "convertall.pubspecSource" ./pubspec.lock.json)
        // {
          supportedFeatures = [ ];
        }
      )
    ];
  };

  meta = {
    homepage = "https://convertall.bellz.org";
    description = "Graphical unit converter";
    mainProgram = "convertall";
    license = lib.licenses.gpl2Plus;
    maintainers = with lib.maintainers; [
      Luflosi
    ];
    # macOS desktop builds are supported by buildFlutterApplication through the
    # nixpkgs built-in plugin layer (no CocoaPods); see build-flutter-application.nix.
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
