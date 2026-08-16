{
  lib,
  callPackage,
  runCommand,
  makeWrapper,
  wrapGAppsHook3,
  buildDartApplication,
  cacert,
  glib,
  flutter,
  pkg-config,
  buildPackages,
  stdenv,
  darwin,
  rsync,
  xcbuild,
  clang,
  swift,
  python3,
}:
let
  # The target Flutter platform is selected automatically when
  # `targetFlutterPlatform` is not given, mirroring the flutter_tools default:
  # Linux desktop on Linux hosts and macOS desktop on Darwin hosts. It must be
  # derived in a single place so that both the SDK configuration and the
  # variant selection below agree.
  inferTargetFlutterPlatform =
    stdenv:
    if stdenv.targetPlatform.isLinux then
      "linux"
    else if stdenv.targetPlatform.isDarwin then
      "macos"
    else
      "universal";
in
lib.extendMkDerivation {
  constructDrv =
    argsFn:
    let
      evalArgs = lib.fix argsFn;
      targetFlutterPlatform = evalArgs.targetFlutterPlatform or (inferTargetFlutterPlatform stdenv);

      minimalFlutter = flutter.override {
        supportedTargetFlutterPlatforms = [
          "universal"
          targetFlutterPlatform
        ];
      };

      buildAppWith = flutter: buildDartApplication.override { dart = flutter; };
    in
    buildAppWith minimalFlutter (
      finalAttrs:
      let
        args = argsFn finalAttrs;
      in
      args
      // {
        passthru = (args.passthru or { }) // {
          multiShell = buildAppWith flutter args;
        };
      }
    );

  extendDrvArgs =
    finalAttrs:
    args@{
      pubGetScript ? null,
      flutterBuildFlags ? [ ],
      targetFlutterPlatform ? inferTargetFlutterPlatform stdenv,
      extraWrapProgramArgs ? "",
      flutterMode ? null,
      ...
    }:
    let
      hasEngine = flutter ? engine && flutter.engine != null && flutter.engine.meta.available;
      flutterMode' = args.flutterMode or (if hasEngine then flutter.engine.runtimeMode else "release");

      flutterFlags = lib.optional hasEngine "--local-engine host_${flutterMode'}${
        lib.optionalString (!flutter.engine.isOptimized) "_unopt"
      }";

      flutterBuildFlags' = [
        "--${flutterMode'}"
      ]
      ++ (args.flutterBuildFlags or [ ])
      ++ flutterFlags;

      universal = args // {
        flutterMode = flutterMode';
        flutterFlags = flutterFlags;
        flutterBuildFlags = flutterBuildFlags';

        sdkSetupScript = ''
          # Pub needs SSL certificates. Dart normally looks in a hardcoded path.
          # https://github.com/dart-lang/sdk/blob/3.1.0/runtime/bin/security_context_linux.cc#L48
          #
          # Dart does not respect SSL_CERT_FILE...
          # https://github.com/dart-lang/sdk/issues/48506
          # ...and Flutter does not support --root-certs-file, so the path cannot be manually set.
          # https://github.com/flutter/flutter/issues/56607
          # https://github.com/flutter/flutter/issues/113594
          #
          # libredirect is of no use either, as Flutter does not pass any
          # environment variables (including LD_PRELOAD) to the Pub process.
          #
          # Instead, Flutter is patched to allow the path to the Dart binary used for
          # Pub commands to be overriden.
          export NIX_FLUTTER_PUB_DART="${
            runCommand "dart-with-certs" { nativeBuildInputs = [ makeWrapper ]; } ''
              mkdir -p "$out/bin"
              makeWrapper ${flutter.dart}/bin/dart "$out/bin/dart" \
                --add-flags "--root-certs-file=${cacert}/etc/ssl/certs/ca-bundle.crt"
            ''
          }/bin/dart"

          export HOME="$NIX_BUILD_TOP"
          flutter config $flutterFlags --no-analytics &>/dev/null # mute first-run
          flutter config $flutterFlags ${
            if targetFlutterPlatform == "macos" then "--enable-macos-desktop" else "--enable-linux-desktop"
          } >/dev/null
        '';

        pubGetScript =
          args.pubGetScript
            or "flutter${lib.optionalString hasEngine " --local-engine $flutterMode"} pub get";

        sdkSourceBuilders = {
          # https://github.com/dart-lang/pub/blob/68dc2f547d0a264955c1fa551fa0a0e158046494/lib/src/sdk/flutter.dart#L81
          "flutter" =
            name:
            runCommand "flutter-sdk-${name}" { passthru.packageRoot = "."; } ''
              for path in '${flutter}/packages/${name}' '${flutter}/bin/cache/pkg/${name}'; do
                if [ -d "$path" ]; then
                  ln -s "$path" "$out"
                  break
                fi
              done

              if [ ! -e "$out" ]; then
                echo 1>&2 'The Flutter SDK does not contain the requested package: ${name}!'
                exit 1
              fi
            '';
          # https://github.com/dart-lang/pub/blob/e1fbda73d1ac597474b82882ee0bf6ecea5df108/lib/src/sdk/dart.dart#L80
          "dart" =
            name:
            runCommand "dart-sdk-${name}" { passthru.packageRoot = "."; } ''
              for path in '${flutter.dart}/pkg/${name}'; do
                if [ -d "$path" ]; then
                  ln -s "$path" "$out"
                  break
                fi
              done

              if [ ! -e "$out" ]; then
                echo 1>&2 'The Dart SDK does not contain the requested package: ${name}!'
                exit 1
              fi
            '';
        };

        # https://github.com/flutter/flutter/blob/edada7c56edf4a183c1735310e123c7f923584f1/packages/flutter_tools/lib/src/dart/pub.dart#L804
        extraPackageConfigSetup = lib.optionalString (lib.versionOlder flutter.version "3.34.0") ''
          if [ "$("${lib.getExe buildPackages.yq}" '.flutter.generate // false' pubspec.yaml)" = "true" ]; then
            if ! "${lib.getExe buildPackages.jq}" -e '.packages[] | select(.name == "flutter_gen")' "$out" >/dev/null 2>&1; then
              export TEMP_PACKAGES=$(mktemp)
              "${lib.getExe buildPackages.jq}" '.packages |= . + [{
                name: "flutter_gen",
                rootUri: "flutter_gen",
                languageVersion: "2.12"
              }]' "$out" > "$TEMP_PACKAGES"
              cp "$TEMP_PACKAGES" "$out"
              rm "$TEMP_PACKAGES"
              unset TEMP_PACKAGES
            fi
          fi
        '';
      };
    in
    {
      inherit universal;

      linux = universal // {
        outputs = universal.outputs or [ ] ++ [ "debug" ];

        nativeBuildInputs = (universal.nativeBuildInputs or [ ]) ++ [
          wrapGAppsHook3

          # Flutter requires pkg-config for Linux desktop support, and many plugins
          # attempt to use it.
          #
          # It is available to the `flutter` tool through its wrapper, but it must be
          # added here as well so the setup hook adds plugin dependencies to the
          # pkg-config search paths.
          pkg-config
        ];

        buildInputs = (universal.buildInputs or [ ]) ++ [ glib ];

        dontDartBuild = true;
        buildPhase =
          universal.buildPhase or ''
            runHook preBuild

            mkdir -p build/flutter_assets/fonts

            flutter build linux -v --split-debug-info="$debug" $flutterBuildFlags

            runHook postBuild
          '';

        dontDartInstall = true;
        installPhase =
          universal.installPhase or ''
            runHook preInstall

            built=build/linux/*/$flutterMode/bundle

            mkdir -p $out/bin
            mkdir -p $out/app
            mv $built $out/app/$pname

            for f in $(find $out/app/$pname -iname "*.desktop" -type f); do
              install -D $f $out/share/applications/$(basename $f)
            done

            for f in $(find $out/app/$pname -maxdepth 1 -type f); do
              ln -s $f $out/bin/$(basename $f)
            done

            # make *.so executable
            find $out/app/$pname -iname "*.so" -type f -exec chmod +x {} +

            # remove stuff like /build/source/packages/ubuntu_desktop_installer/linux/flutter/ephemeral
            for f in $(find $out/app/$pname -executable -type f); do
              if patchelf --print-rpath "$f" | grep /build; then # this ignores static libs (e,g. libapp.so) also
                echo "strip RPath of $f"
                newrp=$(patchelf --print-rpath $f | sed -r "s|/build.*ephemeral:||g" | sed -r "s|/build.*profile:||g")
                patchelf --set-rpath "$newrp" "$f"
              fi
            done

            runHook postInstall
          '';

        dontWrapGApps = true;
        extraWrapProgramArgs = ''
          ''${gappsWrapperArgs[@]} \
          ${extraWrapProgramArgs}
        '';
      };

      macos =
        let
          _assert =
            if stdenv.hostPlatform.isDarwin then
              null
            else
              throw ''
                buildFlutterApplication: the macOS target can only be built on a Darwin host
                (the Swift/Clang Darwin toolchains and the Flutter macOS engine artifacts are
                not available for cross-compilation from '${stdenv.hostPlatform.system}').
              '';
        in
        assert _assert == null;
        universal
        // {
          outputs = universal.outputs or [ ] ++ [ "debug" ];

          # Architecture name as understood by flutter_tools for Darwin targets.
          darwinArchs = if stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64";

          nativeBuildInputs = (universal.nativeBuildInputs or [ ]) ++ [
            darwin.DarwinTools

            # Ad-hoc sign the .app bundle (sigtool/cctools, no Xcode needed).
            # macOS requires every Mach-O binary to carry a (at least ad-hoc)
            # code signature, otherwise the OS refuses to launch it.
            darwin.autoSignDarwinBinariesHook

            # `flutter assemble` invokes rsync when unpacking the engine dSYM.
            rsync

            # plutil (accessed via PATH) for plist processing.
            xcbuild

            # Toolchain used to compile the Runner executable.
            clang
            swift

            # Plugin source collection / source rewriting during the build.
            python3
          ];

          buildInputs = (universal.buildInputs or [ ]);

          dontDartBuild = true;
          buildPhase =
            universal.buildPhase or ''
                              runHook preBuild

                              # Sources checked out from version control (e.g. via git) can be readonly.
                              chmod -R u+w .

                              # Extract a value from an .xcconfig file (ignores #include lines).
                              xcconfigValue() {
                                local file="$1" key="$2"
                                [ -f "$file" ] || return 0
                                local v=""
                                if grep -qE "^[[:space:]]*''${key}[[:space:]]*=" "$file" 2>/dev/null; then
                                  v=$(grep -E "^[[:space:]]*''${key}[[:space:]]*=" "$file" | head -1 | sed -E "s/^[[:space:]]*''${key}[[:space:]]*=[[:space:]]*//; s/[[:space:]]*$//")
                                fi
                                if [ -n "$v" ]; then
                                  printf '%s' "$v"
                                fi
                              }

                              export HOME=$(mktemp -d)

                              # 1. Produce the Flutter framework artifacts without Xcode.
                              #    `flutter assemble` is the Xcode-independent interface flutter_tools
                              #    uses internally; `*_macos_bundle_flutter_assets` emits App.framework,
                              #    FlutterMacOS.framework and ephemeral build outputs into
                              #    build/macos/Build/Products/<mode> (the conventional layout).
                              export BUILT_PRODUCTS_DIR="$PWD/build/macos/Build/Products/$flutterMode"
                              mkdir -p "$BUILT_PRODUCTS_DIR" "$debug"

                              assembleFlags=()
                              for flag in $flutterBuildFlags; do
                                case "$flag" in
                                  --dart-define=*)
                                    # flutter_tools expects dart defines to be
                                    # base64-encoded (see decodeDartDefines in
                                    # flutter_tools/lib/src/build_info.dart); a
                                    # plain value would be rejected by `assemble`.
                                    assembleFlags+=("--dart-define=$(printf '%s' "''${flag#--dart-define=}" | base64 | tr -d '\n')") ;;
                                  --split-debug-info=*) assembleFlags+=("-dSplitDebugInfo=''${flag#--split-debug-info=}") ;;
                                  --obfuscate) assembleFlags+=("-dDartObfuscation=true") ;;
                                  --tree-shake-icons) assembleFlags+=("-dTreeShakeIcons=true") ;;
                                  --target=*) assembleFlags+=("-dTargetFile=''${flag#--target=}") ;;
                                esac
                              done

                              # flutterFlags carries the engine selection
                              # (--local-engine) which flutter_tools resolves
                              # from the artifacts; it must reach this call.
                              # Suppress analytics: flutter_tools blocks on
                              # telemetry when the sandbox has no network.
                              export FLUTTER_SUPPRESS_ANALYTICS=true
                              # shellcheck disable=SC2086
                              flutter assemble --no-version-check $flutterFlags --output="$BUILT_PRODUCTS_DIR/" \
                                -dTargetPlatform=darwin \
                                -dTargetFile=lib/main.dart \
                                -dBuildMode=$flutterMode \
                                -dConfiguration=''${flutterMode^} \
                                -dDarwinArchs=$darwinArchs \
                                -dSplitDebugInfo=$debug \
                                "''${assembleFlags[@]}" \
                                ''${flutterMode}_macos_bundle_flutter_assets

                              # 2. Assemble the .app bundle.
                              appName=$(xcconfigValue macos/Runner/Configs/AppInfo.xcconfig PRODUCT_NAME)
                              appName=''${appName:-$pname}
                              appDir="build/app/$appName.app"
                              mkdir -p "$appDir/Contents/MacOS" "$appDir/Contents/Frameworks"

                              # 3. Compile the Runner.
                              #    The template project's @main entry point is stripped and replaced by a
                              #    programmatic main (macos-runner-main.swift) that reproduces the
                              #    MainMenu.xib behavior without Xcode/ibtool.
                              runnerSources=()
                              for f in macos/Runner/*.swift; do
                                if [ -f "$f" ]; then
                                  runnerSources+=("$f")
                                fi
                              done
                              if [ ''${#runnerSources[@]} -gt 0 ]; then
                                runnerDir=$(mktemp -d)
                                for f in "''${runnerSources[@]}"; do
                                  cp "$f" "$runnerDir/"
                                done
                                # `flutter assemble` regenerates an ephemeral
                                # GeneratedPluginRegistrant.swift that imports the native
                                # plugin modules normally compiled by CocoaPods, and
                                # `flutter pub get` may have produced one in the source
                                # tree as well. nixpkgs builds without CocoaPods, so we
                                # substitute the nixpkgs built-in registrant: it registers
                                # the macOS plugins whose official implementations use
                                # only Apple frameworks and are compiled directly from
                                # the resolved pub sources below. Plugins with third-party
                                # pod dependencies are not supported in this build model.
                                mkdir -p macos/Flutter

                                # Collect the macOS plugins: resolve each
                                # dependency's native sources (podspec or
                                # Package.swift), copy them into a scratch dir
                                # and print one TSV line per plugin.
                                                                pluginDir=$(mktemp -d)
                                pluginSwiftFiles=()
                                pluginObjCFiles=()
                                pluginRegistrations=()
                                objcPluginNames=()
                                haveObjCPlugins=0
                                objcFrameworks=()
                                packageConfig="$PWD/.dart_tool/package_config.json"
                                if [ -f "$packageConfig" ]; then
                                  # collect.py failure must not be silent:
                                  # print its stderr, then fail the build.
                                  set +e
                                  python3 '${./macos-plugin-collect.py}' "$packageConfig" "$pluginDir" > "$pluginDir/collect.out" 2> "$pluginDir/collect.err"
                                  collect_rc=$?
                                  set -e
                                  if [ -s "$pluginDir/collect.err" ]; then
                                    cat "$pluginDir/collect.err" >&2
                                  fi
                                  if [ "$collect_rc" != 0 ]; then
                                    echo "macos-plugin-collect failed with exit code $collect_rc" >&2
                                    exit 1
                                  fi
                                  while IFS=$'\t' read -r pluginName pluginClass srcType sourceFiles publicHeaderDir frameworks; do
                                    [ -n "$pluginName" ] || continue
                                    dest="$pluginDir/$pluginName"
                                    if [ "$srcType" = "swift" ]; then
                                      pluginSwiftFiles+=($(find "$dest" -name '*.swift'))
                                      pluginRegistrations+=("$pluginClass.register(with: registry.registrar(forPlugin: \"$pluginName\"))")
                                    else
                                      # ObjC plugin: compile every source with
                                      # clang (-fmodules enables @import and its
                                      # autolinking); add the podspec's public
                                      # header dir when declared.
                                      incArg=("-I$dest")
                                      [ "$publicHeaderDir" != "-" ] && incArg=(-I "$dest/$publicHeaderDir")
                                      for m in $(find "$dest" -name '*.m'); do
                                        clang -fobjc-arc -fmodules -c "$m" "''${incArg[@]}" \
                                          -F "$BUILT_PRODUCTS_DIR" -o "''${m%.m}.o" || exit 1
                                      done
                                      pluginObjCFiles+=($(find "$dest" -name '*.o'))
                                      haveObjCPlugins=1
                                      objcPluginNames+=("$pluginName:$pluginClass")
                                      # Keep only real system frameworks:
                                      # FlutterMacOS is linked below and
                                      # Cocoa/Foundation/AppKit autolink.
                                      for fw in $frameworks; do
                                        case "$fw" in
                                          Flutter | FlutterMacOS | Foundation | Cocoa | AppKit) ;;
                                          *)
                                            case " $objcFrameworks " in
                                              *" ''${fw} "*) ;;
                                              *) objcFrameworks+=("$fw") ;;
                                            esac
                                            ;;
                                        esac
                                      done
                                    fi
                                  done < "$pluginDir/collect.out"
                                fi

                                # ObjC plugin registrar: every plugin class is
                                # resolved at runtime via NSClassFromString so
                                # no header/class mapping is hardcoded.
                                linkObjCFiles=()
                                swiftFlags=()
                                if [ "$haveObjCPlugins" = "1" ]; then
                                  python3 - "$pluginDir" "''${objcPluginNames[@]}" <<'PYEOF'
                import os
                import sys

                outdir, *entries = sys.argv[1:]
                m_path = os.path.join(outdir, "nixpkgs_objc_plugins.m")
                with open(m_path, "w") as f:
                    f.write("#import <FlutterMacOS/FlutterMacOS.h>\n")
                    for entry in entries:
                        pname, pclass = entry.split(":", 1)
                        f.write(f"static void RegisterPlugin{pname}(id<FlutterPluginRegistry> r) {{\n")
                        f.write(f"  Class c = NSClassFromString(@\"{pclass}\");\n")
                        f.write("  if (c && [c respondsToSelector:@selector(registerWithRegistrar:)])\n")
                        f.write(f"    [c registerWithRegistrar:[r registrarForPlugin:@\"{pname}\"]];\n")
                        f.write("}\n")
                    f.write("void RegisterNixpkgsObjCPlugins(id<FlutterPluginRegistry> registry) {\n")
                    for entry in entries:
                        f.write(f"  RegisterPlugin{entry.split(':', 1)[0]}(registry);\n")
                    f.write("}\n")
                h_path = os.path.join(outdir, "nixpkgs_plugins_bridging.h")
                with open(h_path, "w") as f:
                    f.write("#import <FlutterMacOS/FlutterMacOS.h>\n")
                    f.write("void RegisterNixpkgsObjCPlugins(id<FlutterPluginRegistry> registry);\n")
                PYEOF
                                  clang -fobjc-arc -c "$pluginDir/nixpkgs_objc_plugins.m" \
                                    -F "$BUILT_PRODUCTS_DIR" -o "$pluginDir/nixpkgs_objc_plugins.o" || exit 1
                                  linkObjCFiles+=("''${pluginObjCFiles[@]}" "$pluginDir/nixpkgs_objc_plugins.o")
                                  swiftFlags+=(-import-objc-header "$pluginDir/nixpkgs_plugins_bridging.h")
                                  # ObjC has no autolinking; link the frameworks
                                  # its sources import explicitly.
                                  for fw in "''${objcFrameworks[@]}"; do
                                    swiftFlags+=(-framework "$fw")
                                  done
                                fi

                                # Generate the built-in plugin registrant.
                                {
                                  cat <<'SWIFT_EOF'
                //
                //  Generated file. Do not edit.
                //
                //  Nixpkgs buildFlutterApplication (macOS): built-in plugin
                //  registrant. Registers the macOS plugins whose official
                //  implementations are pure Apple frameworks, compiled directly
                //  from the pub sources (no CocoaPods).

                import FlutterMacOS
                import Foundation

                func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
                SWIFT_EOF
                                  for reg in "''${pluginRegistrations[@]}"; do
                                    printf '  %s\n' "$reg"
                                  done
                                  if [ "$haveObjCPlugins" = "1" ]; then
                                    printf '  RegisterNixpkgsObjCPlugins(registry)\n'
                                  fi
                                  printf '}\n'
                                } > macos/Flutter/GeneratedPluginRegistrant.swift
                                cp macos/Flutter/GeneratedPluginRegistrant.swift "$runnerDir/"
                                chmod u+w "$runnerDir"/*.swift
                                sed -i -e 's/^@main[[:space:]]*$//' -e 's/^@NSApplicationMain[[:space:]]*$//' "$runnerDir"/*.swift
                                cp '${./macos-runner-main.swift}' "$runnerDir/main.swift"
                                swiftc -O -module-name Runner "$runnerDir"/*.swift \
                                  "''${pluginSwiftFiles[@]}" \
                                  "''${linkObjCFiles[@]}" \
                                  "''${swiftFlags[@]}" \
                                  -F "$BUILT_PRODUCTS_DIR" -framework FlutterMacOS \
                                  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
                                  -o "$appDir/Contents/MacOS/$appName"
                              else
                                # Non-template projects without Swift sources: plain ObjC runner.
                                clang -fobjc-arc '${./macos-runner-objc/main.m}' \
                                  -F "$BUILT_PRODUCTS_DIR" -framework FlutterMacOS -framework Cocoa \
                                  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
                                  -o "$appDir/Contents/MacOS/$appName"
                              fi

                              # 4. Info.plist: substitute the $(...) placeholders of the template
                              #    plist (keeping any user-defined keys) and drop the nib entry.
                              flutterVersion=$(sed -nE 's/^version:[[:space:]]*([0-9][^[:space:]]*).*/\1/p' pubspec.yaml | head -1)
                              flutterBuildName=''${flutterVersion%+*}
                              flutterBuildNumber=''${flutterVersion#*+}
                              [ "$flutterBuildNumber" = "$flutterVersion" ] && flutterBuildNumber=1
                              productBundleId=$(xcconfigValue macos/Runner/Configs/AppInfo.xcconfig PRODUCT_BUNDLE_IDENTIFIER)
                              productBundleId=''${productBundleId:-com.example.$pname}
                              productCopyright=$(xcconfigValue macos/Runner/Configs/AppInfo.xcconfig PRODUCT_COPYRIGHT)
                              developmentLanguage=$(xcconfigValue macos/Runner/Configs/AppInfo.xcconfig DEVELOPMENT_LANGUAGE)
                              developmentLanguage=''${developmentLanguage:-en}
                              deploymentTarget=$(xcconfigValue macos/Runner/Configs/Debug.xcconfig MACOSX_DEPLOYMENT_TARGET)
                              deploymentTarget=''${deploymentTarget:-12.0}

                              sed \
                                -e "s|\$(DEVELOPMENT_LANGUAGE)|$developmentLanguage|g" \
                                -e "s|\$(EXECUTABLE_NAME)|$appName|g" \
                                -e "s|\$(PRODUCT_NAME)|$appName|g" \
                                -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$productBundleId|g" \
                                -e "s|\$(FLUTTER_BUILD_NAME)|$flutterBuildName|g" \
                                -e "s|\$(FLUTTER_BUILD_NUMBER)|$flutterBuildNumber|g" \
                                -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|$deploymentTarget|g" \
                                -e "s|\$(PRODUCT_COPYRIGHT)|$productCopyright|g" \
                                -e '/<key>NSMainNibFile<\/key>/,+1d' \
                                macos/Runner/Info.plist > "$appDir/Contents/Info.plist"

                              # A placeholder left behind (e.g. when the template
                              # plist changes) would silently produce a broken
                              # bundle, so fail instead of shipping it.
                              if grep -qF '$(' "$appDir/Contents/Info.plist"; then
                                echo "error: unsubstituted \$() placeholders remain in $appDir/Contents/Info.plist" >&2
                                exit 1
                              fi

                              # 5. Embed the frameworks.
                              cp -R "$BUILT_PRODUCTS_DIR/App.framework" "$appDir/Contents/Frameworks/"
                              cp -R "$BUILT_PRODUCTS_DIR/FlutterMacOS.framework" "$appDir/Contents/Frameworks/"

                              runHook postBuild
            '';

          dontDartInstall = true;
          installPhase =
            universal.installPhase or ''
              runHook preInstall

              built=build/app/*.app

              mkdir -p $out/app $out/bin
              mv $built $out/app/

              # Binaries in $out/bin would otherwise be symlinks into the .app;
              # macOS resolves the main bundle from the executable path and a
              # symlink (or wrapper script) breaks that resolution, losing
              # Info.plist/flutter_assets lookups. Generate a small wrapper that
              # execs the real binary with argv[0] set to its store path so the
              # main bundle resolves correctly.
              for f in $(find $out/app -path "*/Contents/MacOS/*" -type f); do
                wrapper=$out/bin/$(basename $f)
                cat > $wrapper <<WRAP
              #!/bin/sh
              exec -a $f $f "\$@"
              WRAP
                chmod +x $wrapper
              done

              runHook postInstall
            '';
        };

      web = universal // {
        dontDartBuild = true;
        buildPhase =
          universal.buildPhase or ''
            runHook preBuild

            mkdir -p build/flutter_assets/fonts

            flutter build web -v $flutterBuildFlags

            runHook postBuild
          '';

        dontDartInstall = true;
        installPhase =
          universal.installPhase or ''
            runHook preInstall

            cp -r build/web "$out"

            runHook postInstall
          '';
      };
    }
    .${targetFlutterPlatform} or (throw "Unsupported Flutter host platform: ${targetFlutterPlatform}");
}
