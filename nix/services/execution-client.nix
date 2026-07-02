{ packages }:

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf
    types filterAttrs escapeShellArgs literalExpression
    optionals optionalAttrs optionalString;

  cfg = config.services.nimbus-execution-client;
  system = pkgs.stdenv.hostPlatform.system;

  toml = pkgs.formats.toml { };
  removeNull = k: v: v != null;
  cleanSettings = filterAttrs removeNull cfg.settings;
  configFile = toml.generate "nimbus-execution-client.toml" cleanSettings;
in {
  options = {
    services = {
      nimbus-execution-client = {
        enable = mkEnableOption "Nimbus Execution Client service.";

        package = mkOption {
          type = types.package;
          default = packages.${system}.nimbus_execution_client;
          defaultText = literalExpression "inputs.nimbus-eth2.packages.${system}.execution-client";
          description = lib.mdDoc "Package to use as Go Ethereum node.";
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          description = lib.mdDoc "Additional arguments passed to node.";
          default = [];
        };

        settings = mkOption {
          description = "TOML config file settings for Nimbus execution client.";
          default = {};
          type = types.submodule {
            freeformType = toml.type;
            options = {
              # LOGGING AND DEBUGGING OPTIONS

              log-level = mkOption {
                type = types.str;
                default = "info";
                description = "Logging level for the node.";
              };

              log-format = mkOption {
                type = types.str;
                default = "auto";
                description = "Logging formatting (auto, colors, nocolors, json).";
              };

              # PERFORMANCE OPTIONS

              num-threads = mkOption {
                type = types.int;
                default = 0;
                description = "Number of worker threads. Use 0 to detect CPU cores.";
              };

              # ETHEREUM OPTIONS

              data-dir = mkOption {
                type = types.path;
                default = "/var/lib/nimbus-execution-client";
                description = "Directory for Nimbus Eth2 blockchain data.";
              };

              era-dir = mkOption {
                type = types.nullOr types.path;
                default = null;
                description = "Directory for ERA archive files.";
              };

              era1-dir = mkOption {
                type = types.nullOr types.path;
                default = null;
                description = "Directory for ERA1 archive files.";
              };

              # PAYLOAD BUILDING OPTIONS

              network = mkOption {
                type = types.listOf types.str;
                default = ["mainnet"];
                description = "Name of Eth2 network to connect to.";
              };

              gas-limit = mkOption {
                type = types.int;
                default = 60000000;
                description = "Desired gas limit when building an execution payload.";
              };

              extra-data = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "Nimbus/v0.3.0-32def7b5";
                description = "Value of extraData field when building an execution payload.";
              };

              # NETWORKING OPTIONS

              agent-string = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Node agent string which is used as identifier in network";
              };

              max-peers = mkOption {
                type = types.int;
                default = 25;
                description = "Maximum number of peers to connect to.";
              };

              nat = mkOption {
                type = types.str;
                default = "any";
                example = "extip:12.34.56.78";
                description = "Way to detect public IP address of the node to advertise.";
              };

              # LOCAL SERVICES OPTIONS

              listen-address = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Listening IP address for Ethereum P2P and Discovery traffic";
              };

              tcp-port = mkOption {
                type = types.int;
                default = 30303;
                description = "Listen port for libp2p protocol.";
              };

              udp-port = mkOption {
                type = types.int;
                default = 30303;
                description = "Listen port for libp2p protocol.";
              };

              metrics = mkEnableOption "Enable the built-in metrics HTTP server";

              metrics-address = mkOption {
                type = types.str;
                default = "127.0.0.1";
                description = "Metrics address for execution client.";
              };

              metrics-port = mkOption {
                type = types.int;
                default = 9100;
                description = "Metrics port for execution client.";
              };

              http-address = mkOption {
                type = types.str;
                default = "127.0.0.1";
                description = "Listening address of the HTTP server(rpc, ws)";
              };

              http-port = mkOption {
                type = types.int;
                default = 8545;
                description = "Listening port of the HTTP server(rpc, ws)";
              };

              rpc = mkEnableOption "Enable the JSON-RPC server.";

              rpc-api = mkOption {
                type = types.listOf types.str;
                default = ["eth"];
                description = "Enable specific set of RPC API (available: eth, debug, admin)";
              };

              ws = mkEnableOption "Enable the Websocket JSON-RPC server.";

              ws-api = mkOption {
                type = types.listOf types.str;
                default = ["eth"];
                description = "Enable specific set of Websocket RPC API (available: eth, debug, admin)";
              };

              engine-api = mkEnableOption "Enable the Engine API";

              engine-api-ws = mkEnableOption "Enable the WebSocket Engine API";

              engine-api-address = mkOption {
                type = types.str;
                default = "127.0.0.1";
                description = "Listening address for the Engine API(http and ws).";
              };

              engine-api-port = mkOption {
                type = types.port;
                default = 8551;
                description = "Listening port for the Engine API(http and ws).";
              };

              allowed-origins = mkOption {
                type = types.listOf types.str;
                default = ["*"];
                description = "Comma-separated list of domains from which to accept cross origin requests,";
              };

              prune = mkEnableOption "Enable background pruning of expired block bodies and receipts";

              jwt-secret = mkOption {
                type = types.nullOr types.path;
                default = null;
                description = "Path of JWT secret for Auth RPC endpoint.";
              };
            };
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    environment.etc."ethereum/nimbus-execution-client.toml".source = configFile;

    systemd.services.nimbus-execution-client = {
      enable = true;
      serviceConfig = {
        DynamicUser = true;

        # Hardening measures
        PrivateTmp = "true";
        ProtectSystem = "full";
        NoNewPrivileges = "true";
        PrivateDevices = "true";
        MemoryDenyWriteExecute = "true";
        WorkingDirectory = "%S/nimbus-execution-client";
        StateDirectory = "nimbus-execution-client";
        LoadCredential = optionals (cfg.settings.jwt-secret != null) [
          "jwt-secret:${cfg.settings.jwt-secret}"
        ];

        Restart = "on-failure";
        ExecStart = let
          jwtFlag = optionalString (cfg.settings.jwt-secret != null)
            "--jwt-secret=%d/jwt-secret";
        in ''
          ${cfg.package}/bin/nimbus_execution_client \
            --config-file=${configFile} ${jwtFlag} \
            ${escapeShellArgs cfg.extraArgs}
        '';
      };
      wantedBy = [ "multi-user.target" ];
      requires = [ "network.target" ];
    };
  };
}
