{ packages }:

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf
    types filterAttrs escapeShellArgs literalExpression;

  cfg = config.services.nimbus-verified-proxy;
  system = pkgs.stdenv.hostPlatform.system;

  toml = pkgs.formats.toml { };
  removeNull = k: v: v != null;
  cleanSettings = filterAttrs removeNull cfg.settings;
  configFile = toml.generate "nimbus-verified-proxy.toml" cleanSettings;
in {
  options = {
    services = {
      nimbus-verified-proxy = {
        enable = mkEnableOption "Nimbus Verified Proxy service.";

        package = mkOption {
          type = types.package;
          default = packages.${system}.nimbus_verified_proxy;
          defaultText = literalExpression "inputs.nimbus-eth1.packages.${system}.nimbus_verified_proxy";
          description = lib.mdDoc "Package to use as Nimbus Verified Proxy.";
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          description = lib.mdDoc "Additional arguments passed to Nimbus Verified Proxy.";
          default = [];
        };

        settings = mkOption {
          description = "TOML config file settings for Nimbus Verified Proxy.";
          default = {};
          type = types.submodule {
            freeformType = toml.type;
            options = {
              # LOGGING OPTIONS

              log-level = mkOption {
                type = types.str;
                default = "INFO";
                description = "Logging level for the proxy.";
              };

              log-format = mkOption {
                type = types.str;
                default = "auto";
                description = "Logging format (auto, colors, nocolors, json).";
              };

              # NETWORK OPTIONS

              network = mkOption {
                type = types.str;
                default = "mainnet";
                description = "Network to serve (mainnet, hoodi, sepolia, op-mainnet, base-mainnet, op-sepolia).";
              };

              trusted-block-root = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Recent trusted finalized block root used to initialize the light client.";
              };

              execution-api-url = mkOption {
                type = types.listOf types.str;
                default = [];
                description = "Execution API provider URLs. At least one is required.";
              };

              op-execution-api-url = mkOption {
                type = types.listOf types.str;
                default = [];
                description = "L2 execution API provider URLs for OP Stack networks.";
              };

              listen-url = mkOption {
                type = types.listOf types.str;
                default = [ "http://127.0.0.1:8545" ];
                description = "URLs where the proxy listens for HTTP or WebSocket requests.";
              };

              op-listen-url = mkOption {
                type = types.listOf types.str;
                default = [ "http://127.0.0.1:8546" ];
                description = "URLs where the OP Stack proxy listens for HTTP or WebSocket requests.";
              };

              beacon-api-url = mkOption {
                type = types.listOf types.str;
                default = [];
                description = "Beacon API provider URLs. Required unless P2P backend is enabled.";
              };

              private-tx-url = mkOption {
                type = types.listOf types.str;
                default = [];
                description = "Private transaction relay URLs.";
              };

              archive-url = mkOption {
                type = types.listOf types.str;
                default = [];
                description = "Archive execution API URLs used for eth_getProof requests.";
              };

              # P2P LIGHT CLIENT BACKEND OPTIONS

              p2p = mkEnableOption "P2P light client data backend.";

              p2p-tcp-port = mkOption {
                type = types.port;
                default = 9000;
                description = "Listening TCP port for the P2P light client backend.";
              };

              p2p-udp-port = mkOption {
                type = types.port;
                default = 9000;
                description = "Listening UDP port for the P2P light client backend.";
              };

              p2p-max-peers = mkOption {
                type = types.int;
                default = 160;
                description = "Target number of peers for the P2P light client backend.";
              };

              p2p-bootstrap-nodes-file = mkOption {
                type = types.nullOr types.path;
                default = null;
                description = "File containing bootstrap node ENRs, one per line.";
              };

              p2p-nat = mkOption {
                type = types.str;
                default = "any";
                example = "extip:12.34.56.78";
                description = "NAT traversal mode for the P2P backend.";
              };
            };
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.settings.trusted-block-root != null;
        message = "services.nimbus-verified-proxy.settings.trusted-block-root must be set.";
      }
      {
        assertion = cfg.settings.execution-api-url != [];
        message = "services.nimbus-verified-proxy.settings.execution-api-url must contain at least one URL.";
      }
      {
        assertion = cfg.settings.p2p || cfg.settings.beacon-api-url != [];
        message = "Set services.nimbus-verified-proxy.settings.beacon-api-url or enable P2P.";
      }
      {
        assertion = !(lib.elem cfg.settings.network [ "op-mainnet" "base-mainnet" "op-sepolia" ])
          || cfg.settings.op-execution-api-url != [];
        message = "OP Stack networks require services.nimbus-verified-proxy.settings.op-execution-api-url.";
      }
    ];

    environment.etc."ethereum/nimbus-verified-proxy.toml".source = configFile;

    systemd.services.nimbus-verified-proxy = {
      enable = true;
      serviceConfig = {
        DynamicUser = true;

        # Hardening measures
        PrivateTmp = "true";
        ProtectSystem = "full";
        NoNewPrivileges = "true";
        PrivateDevices = "true";
        MemoryDenyWriteExecute = "true";

        Restart = "on-failure";
        ExecStart = ''
          ${cfg.package}/bin/nimbus_verified_proxy \
            --config-file=${configFile} \
            ${escapeShellArgs cfg.extraArgs}
        '';
      };
      wantedBy = [ "multi-user.target" ];
      requires = [ "network.target" ];
    };
  };
}
