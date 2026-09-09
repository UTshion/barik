# Installs the unsigned Barik.app that this repo's tag-triggered CI
# (.github/workflows/release.yml) publishes as Barik.zip on the matching
# GitHub Release — no local Xcode build. (SwiftUI apps can't be built inside
# the Nix sandbox: xcodebuild requires an impure Xcode toolchain, so the
# artifact is produced by CI and only *installed* by Nix.)
#
# version/url/hash come from ../release.json, which the release workflow bumps
# on main right after uploading the artifact.
#
# The app is unsigned (CI builds with CODE_SIGNING_ALLOWED=NO). fetchurl does
# not set com.apple.quarantine, so Gatekeeper quarantine is not triggered for
# store paths; if macOS ever objects, ad-hoc sign in installPhase (codesign -s -).
{
  lib,
  stdenvNoCC,
  fetchurl,
  _7zz,
  release,
}:
stdenvNoCC.mkDerivation {
  pname = "barik";
  version = release.version;

  src = fetchurl {
    url = release.url;
    hash = release.hash;
  };

  nativeBuildInputs = [ _7zz ];

  # Barik.zip (ditto --keepParent) has Barik.app at the archive root.
  sourceRoot = ".";

  unpackPhase = ''
    runHook preUnpack
    # -snld preserves the symlinks inside the .app bundle (framework Versions/*).
    ${_7zz}/bin/7zz x -snld "$src"
    runHook postUnpack
  '';

  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Applications"
    cp -R "Barik.app" "$out/Applications/"
    runHook postInstall
  '';

  meta = {
    description = "Lightweight macOS menu bar replacement (UTshion fork)";
    homepage = "https://github.com/UTshion/barik";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
  };
}
