{
  description = "Dev tools for building ocap-merkledag";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          go
          nodejs_22
          typescript
          webpack-cli
          uglify-js
        ];
      };
    };
}
