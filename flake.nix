{
  description = "V2CC Mac mini standard setup";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
  };

  outputs = inputs@{
    nixpkgs,
    nix-darwin,
    home-manager,
    nix-homebrew,
    ...
  }:
  let
    username = import ./local-user.nix;
    userHome = "/Users/${username}";
  in {
    darwinConfigurations."v2cc-test" =
      nix-darwin.lib.darwinSystem {
        modules = [
          home-manager.darwinModules.home-manager
          nix-homebrew.darwinModules.nix-homebrew

          ({ pkgs, ... }: {
            nixpkgs.hostPlatform = "aarch64-darwin";
            system.stateVersion = 6;
            system.primaryUser = username;
            users.users.${username}.home = userHome;

            # Determinate Nix manages Nix itself.
            nix.enable = false;

            environment.systemPackages = with pkgs; [
              git
              home-manager
              nodejs
            ];

            homebrew = {
              enable = true;
              onActivation.cleanup = "none";
              onActivation.autoUpdate = false;
              onActivation.upgrade = false;
              brews = [];
              casks = [];
            };

            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;

            home-manager.users.${username} = {
              home.stateVersion = "25.11";
              home.homeDirectory = userHome;
              programs.home-manager.enable = true;
            };

            # Adopt existing Homebrew installation.
            nix-homebrew = {
              enable = false;
              user = username;
              enableRosetta = false;
              autoMigrate = false;
            };
          })
        ];
      };
  };
}
