{
  description = "zgsld-agetty flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig.url = "github:mitchellh/zig-overlay";
    zig.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, ... } @ inputs:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
      overlays = [ inputs.zig.overlays.default ];
    in
    {
      formatter = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.nixfmt-rfc-style
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit overlays system; };
        in
        {
          default = pkgs.mkShell {
            name = "zgsld-agetty-devshell";
            packages = with pkgs; [
              zigpkgs."0.16.0"
              zls
              linux-pam
            ];
          };
        }
      );
    };
}
