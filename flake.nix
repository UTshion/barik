{
  description = "barik — lightweight macOS menu bar replacement (UTshion fork)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # CI publishes an unsigned arm64 Barik.app only (see .github/workflows/release.yml).
      systems = [ "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      # Which released artifact this revision installs. Bumped automatically on
      # main by the tag-triggered release workflow — don't edit by hand unless
      # deliberately repointing at an older release.
      release = builtins.fromJSON (builtins.readFile ./release.json);
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          barik = pkgs.callPackage ./nix/package.nix { inherit release; };
        in
        {
          inherit barik;
          default = barik;
        }
      );

      overlays.default = final: prev: {
        barik = final.callPackage ./nix/package.nix { inherit release; };
      };
    };
}
