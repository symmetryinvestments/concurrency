{
  description = "Development environment for the concurrency D library";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      supportedSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          mkDlangShell = compiler: pkgs.mkShell {
            packages = [
              pkgs.binutils
              pkgs.dub
              compiler
            ];

            shellHook = ''
              echo "D development shell: $(${compiler}/bin/${compiler.meta.mainProgram} --version | head -n 1), $(dub --version)"
              echo "Build: dub build | Test: dub -c=unittest-release"
            '';
          };
        in
        {
          default = mkDlangShell pkgs.ldc;
          ldc = mkDlangShell pkgs.ldc;
          dmd = mkDlangShell pkgs.dmd;
        });
    };
}
