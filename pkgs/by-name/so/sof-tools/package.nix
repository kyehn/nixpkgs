{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  alsa-lib,
  python3,
}:

stdenv.mkDerivation rec {
  pname = "sof-tools";
  version = "2.13.1";

  src = fetchFromGitHub {
    owner = "thesofproject";
    repo = "sof";
    tag = "v${version}";
    hash = "sha256-01jd14E4/jywrFz3pyvURDcMbvt8/j3TenzHBGtL730=";
  };

  postPatch = ''
    patchShebangs ../scripts/gen-uuid-reg.py
  '';

  nativeBuildInputs = [
    cmake
    python3
  ];
  buildInputs = [ alsa-lib ];
  sourceRoot = "${src.name}/tools";

  meta = with lib; {
    description = "Tools to develop, test and debug SoF (Sund Open Firmware)";
    homepage = "https://thesofproject.github.io";
    license = licenses.bsd3;
    platforms = platforms.unix;
    maintainers = [ maintainers.johnazoidberg ];
    mainProgram = "sof-ctl";
  };
}
