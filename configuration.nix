# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:
let
  secrets = import ./secrets.nix;
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Use the GRUB 2 boot loader.
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  # Define on which hard drive you want to install Grub.
  boot.loader.grub.device = "/dev/sda";

  networking = {
    hostName = "baculanix"; # Define your hostname.
    interfaces."eno1" = {
      ipAddress = secrets.networking.ip;
      prefixLength = secrets.networking.prefix;
    };
    defaultGateway = secrets.networking.gateway;
    nameservers = [ secrets.networking.gateway "8.8.8.8" "8.8.8.9" ];
    enableIPv6 = false;

    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 443 9103 ];
    };
  };

  # Select internationalisation properties.
  i18n = {
    consoleFont = "lat9w-16";
    consoleKeyMap = "slovene";
    defaultLocale = "en_US.UTF-8";
  };

  # List packages installed in system profile. To search by name, run:
  # -env -qaP | grep wget
  environment.systemPackages = with pkgs; [
    # tools
    wget
    tmux
    git
    openssl

    # required by bacula
    perl
  ];

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services = {
    openssh.enable = true;
    openssh.permitRootLogin = "no";

    postgresql.package = pkgs.postgresql92;

    almir = {
      enable = true;
      director_address = "127.0.0.1";
      director_name = "bacula-dir";
      director_password = secrets.passwords.bacula.director;
      sqlalchemy_engine_url = "postgresql://bacula:${secrets.passwords.bacula.dbpassword}@localhost:5432/bacula";
      timezone = "Europe/Ljubljana";
    };

    bacula-dir = {
      enable = true;
      name = "bacula-dir";
      password = secrets.passwords.bacula.director;
      port = 9101;
      extraConfig = ''
      # =====================
      # GENERAL CONFIGURATION
      # =====================

      # Backup cycle
      Schedule {
        Name = "BackupCycle"
        Run = Level=Full 1st sun at 6:00
        Run = Level=Differential 2nd-5th sun at 6:00
        Run = Level=Incremental mon-sat at 6:00
      }

      # Shared storage for all clients
      Storage {
        Name = File
        SDPort = 9103
        Address = ${secrets.networking.bacula.address}
        Password = ${secrets.passwords.bacula.storage}
        Device = FileStorage
        Media Type = File
      }

      # Job defaults
      JobDefs {
        Name = "DefaultJob"
        Type = Backup
        Messages = Standard
        Priority = 10
        FileSet = "DefaultSet"
        Schedule = "BackupCycle"
        Write Bootstrap = "/var/lib/bacula/%c.bsr"
      }

      JobDefs {
        Name = "MySQLBackup"
        Type = Backup
        Messages = Standard
        Priority = 9
        FileSet = "ClientMySQLDump"
        Write Bootstrap = "/var/lib/bacula/%c.bsr"
      }

      # List of files to be backed up
      FileSet {
        Name = "DefaultSet"
        Include {
          Options {
            signature = SHA1
            compression = GZIP1
            noatime = yes
          }
          File = /etc
        }
      }

      FileSet {
        Name = "ClientMySQLDump"
        Include {
          Options {
            signature = SHA1
            compression = GZIP1
            noatime = yes
          }
          File = /var/backups/mysql/mysql_dump.sql
        }
      }


      # =======
      # CATALOG
      # =======

      Catalog {
        Name = Catalog
        dbdriver = "dbi:postgresql"; dbaddress = 127.0.0.1;
        dbname = "bacula"; dbuser = "bacula"; dbpassword = ${secrets.passwords.bacula.dbpassword};
      }
      Client {
        Name = bacula-fd
        Address = ${secrets.networking.bacula.address}
        Catalog = Catalog
        Password = ${secrets.passwords.bacula.client-catalog}
      }
      Schedule {
        Name = "CatalogCycle"
        Run = Full sun-sat at 23:10
      }
      FileSet {
        Name = "Catalog Set"
        Include {
          Options {
            signature = MD5
          }
          File = "/var/lib/bacula/bacula.sql"
        }
      }
      Pool {
        Name = CatalogPool
        Label Format = Catalog-
        Pool Type = Backup
        Recycle = yes
        AutoPrune = yes
        Use Volume Once = yes
        Volume Retention = 200 days
        Maximum Volumes = 210
      }

      Job {
        Name = "BackupCatalog"
        JobDefs ="DefaultJob"
        Client = "bacula-fd"
        FileSet="Catalog Set"
        Schedule = "CatalogCycle"
        Level = Full
        Storage = File
        Messages = Standard
        Pool = CatalogPool
        # This creates an ASCII copy of the catalog
        # Arguments to make_catalog_backup.pl are:
        #  make_catalog_backup.pl <catalog-name>
        RunBeforeJob = "${pkgs.bacula}/etc/make_catalog_backup.pl Catalog"
        # This deletes the copy of the catalog
        RunAfterJob  = "${pkgs.bacula}/etc/delete_catalog_backup"
        Write Bootstrap = "/var/lib/bacula/%n.bsr"
        Priority = 100                   # run after main backups
      }


      # =======
      # RESTORE
      # =======
      # only for placeholding 'Default' pool name
      Pool {
        Name = Default
        Pool Type = Backup
      }
      Job {
        Name = "RestoreFiles"
        Type = Restore
        Client = bacula-fd
        FileSet = "DefaultSet"
        Storage = File
        Pool = Default
        Messages = Standard
        Where = /tmp/bacula-restores
      }


      # ========
      # MESSAGES
      # ========

      # Message delivery for daemon messages (no job).
      Messages {
        Name = Daemon
        mailcommand = "${pkgs.bacula}/sbin/bsmtp -h localhost -f \"\(Bacula\) \<%r\>\" -s \"Bacula daemon message\" %r"
        mail = ${secrets.networking.bacula.email} = all, !skipped, !info
        console = all, !skipped, !saved
        append = "/var/lib/bacula/bacula.log" = all, !skipped
      }

      # ========
      # CLIENTS
      # ========

      # Each client needs:
      # - Client
      # - Job
      # - 3 Pools (full, differential, incremental)


      Client {
        Name = mladipodjetnik-fd
        Address = ${secrets.networking.bacula.client-mladipodjetnik}
        FDPort = 9102
        Catalog = Catalog
        Password = ${secrets.passwords.bacula.client-mladipodjetnik}
      }
      FileSet {
        Name = "mladipodjetnik set"
        Include {
          Options {
            signature = SHA1
            compression = GZIP1
            noatime = yes
          }
          # Add paths to backup
          File = /home/production/niteoweb.mladipodjetnik/var/backups
          File = /home/production/niteoweb.mladipodjetnik/var/blobstorage
        }
      }
      Job {
        Name = backup-mladipodjetnik
        JobDefs = DefaultJob
        Client = mladipodjetnik-fd
        Storage = File
        Level = Incremental
        Pool = Default
        Full Backup Pool = mladipodjetnik-full
        Differential Backup Pool = mladipodjetnik-diff
        Incremental Backup Pool = mladipodjetnik-inc
        FileSet = "mladipodjetnik set"
      }
      Pool {
        Name = mladipodjetnik-full
        Label Format = mladipodjetnik-full-
        Pool Type = Backup
        AutoPrune = yes
        Recycle = yes
        Use Volume Once = yes
        Volume Retention = 2 months
        Maximum Volumes = 10
      }
      Pool {
        Name = mladipodjetnik-diff
        Label Format = mladipodjetnik-diff-
        Pool Type = Backup
        AutoPrune = yes
        Recycle = yes
        Use Volume Once = yes
        Volume Retention = 31 days
        Maximum Volumes = 8
      }
      Pool {
        Name = mladipodjetnik-inc
        Label Format = mladipodjetnik-inc-
        Pool Type = Backup
        AutoPrune = yes
        Recycle = yes
        Use Volume Once = yes
        Volume Retention = 7 days
        Maximum Volumes = 11
      }


      Client {
        Name = omega-fd
        Address = ${secrets.networking.bacula.client-omega}
        FDPort = 9102
        Catalog = Catalog
        Password = ${secrets.passwords.bacula.client-omega}
      }
      FileSet {
        Name = "omega set"
        Include {
          Options {
            signature = SHA1
            compression = GZIP1
            noatime = yes
          }
          File = /etc/buildout
          File = /etc/nginx
          File = /var/backups/postgresql
          File = /home/pypi/packages  

          # Plone 4 sites
          File = /home/puzzle/var/backups
          File = /home/puzzle/var/blobstorage
          File = /home/plr/niteoweb.plr/var/backups
          File = /home/plr/niteoweb.plr/var/blobstorage
          File = /home/office/var/backups
          File = /home/office/var/blobstorage
        }
      }
      Job {
        Name = backup-omega
        JobDefs = DefaultJob
        Client = omega-fd
        Storage = File
        Level = Incremental
        Pool = Default
        Full Backup Pool = omega-full
        Differential Backup Pool = omega-diff
        Incremental Backup Pool = omega-inc
        FileSet = "omega set"
        RunScript {
          RunsWhen = After
          RunsOnSuccess = yes
          RunsOnFailure = no
          RunsOnClient  = no
          Command = "/etc/bacula/notify_dashboard"
        }
      }
      Pool {
        Name = omega-full
        Label Format = omega-full-
        Pool Type = Backup
        AutoPrune = yes
        Recycle = yes
        Use Volume Once = yes
        Volume Retention = 2 months
        Maximum Volumes = 10
      }
      Pool {
        Name = omega-diff
        Label Format = omega-diff-
        Pool Type = Backup
        AutoPrune = yes
        Recycle = yes
        Use Volume Once = yes
        Volume Retention = 31 days
        Maximum Volumes = 8
      }
      Pool {
        Name = omega-inc
        Label Format = omega-inc-
        Pool Type = Backup
        AutoPrune = yes
        Recycle = yes
        Use Volume Once = yes
        Volume Retention = 7 days
        Maximum Volumes = 11
      }
      '';
      extraDirectorConfig = ''
      Maximum Concurrent Jobs = 1
      Messages = Daemon
      '';
      extraMessagesConfig = ''
      # NOTE! If you send to two email or more email addresses, you will need
      #  to replace the %r in the from field (-f part) with a single valid
      #  email address in both the mailcommand and the operatorcommand.
      #  What this does is, it sets the email address that emails would display
      #  in the FROM field, which is by default the same email as they're being
      #  sent to.  However, if you send email to more than one address, then
      #  you'll have to set the FROM address manually, to a single address.
      #  for example, a 'no-reply@mydomain.com', is better since that tends to
      #  tell (most) people that its coming from an automated source.
      mailcommand = "${pkgs.bacula}/sbin/bsmtp -h localhost -f \"\(Bacula\) \<%r\>\" -s \"Bacula: %t %e of %c %l\" %r"
      operatorcommand = "${pkgs.bacula}/sbin/bsmtp -h localhost -f \"\(Bacula\) \<%r\>\" -s \"Bacula: Intervention needed for %j\" %r"
      mail = ${secrets.networking.bacula.email} = all, !skipped, !info
      operator = root@localhost = mount
      console = all, !skipped, !saved
      catalog = all, !skipped, !saved
      '';
    };

    bacula-fd = {
      enable = true;
      name = "bacula-fd";
      port = 9102;
      director."bacula-dir" = {
        password = secrets.passwords.bacula.client-catalog;
      };
      extraClientConfig = ''
      Maximum Concurrent Jobs = 20
      '';
      extraMessagesConfig = ''
      director = bacula-dir = all, !skipped, !restored
      '';
    };

    bacula-sd = {
      enable = true;
      name = "bacula-sd";
      port = 9103;
      device."FileStorage" = {
        archiveDevice = "/media/bacula_disk";
        mediaType = "File";
        extraDeviceConfig = ''
        LabelMedia = yes;
        Random Access = Yes;
        AutomaticMount = yes;
        RemovableMedia = no;
        AlwaysOpen = no;
        '';
      };
      director."bacula-dir" = {
        password = secrets.passwords.bacula.storage;
      };
      extraMessagesConfig = ''
      director = bacula-dir = all
      '';
      extraStorageConfig = ''
      Maximum Concurrent Jobs = 1
      '';
    };

    nginx.enable = true;
    nginx.config = ''
    worker_processes  1;
    error_log  logs/error.log;
    pid        logs/nginx.pid;
    events {
        worker_connections  1024;
    }

    http {
        log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                          '$status $body_bytes_sent "$http_referer" '
                          '"$http_user_agent" "$http_x_forwarded_for"';

        access_log  logs/access.log  main;
        sendfile        on;
        keepalive_timeout  65;

        server {
            listen 0.0.0.0:80;
            server_name bacula.niteoweb.com;
            rewrite ^ https://$server_name$request_uri? permanent;
        }

        server {
            listen 443 ssl;
            server_name ${secrets.networking.bacula.address};
            keepalive_timeout    70;

            access_log /var/log/almir-nginx-access.log;
            error_log /var/log/almir-nginx-error.log;

            ssl_session_cache    shared:SSL:10m;
            ssl_session_timeout  10m;
            ssl_certificate     /etc/nixos/ssl/almir.crt;
            ssl_certificate_key /etc/nixos/ssl/almir.key;

            location / {
                auth_basic "Restricted";
                auth_basic_user_file /etc/nixos/almir.htaccess;

                proxy_pass http://127.0.0.1:35000/;

proxy_redirect              off;
proxy_set_header            Host $host;
proxy_set_header            X-Real-IP $remote_addr;
proxy_set_header            X-Forwarded-For $proxy_add_x_forwarded_for;
client_max_body_size        10m;
client_body_buffer_size     128k;
proxy_connect_timeout       90;
proxy_send_timeout          90;
proxy_read_timeout          90;
proxy_buffer_size           4k;
proxy_buffers               4 32k;
proxy_busy_buffers_size     64k;
proxy_temp_file_write_size  64k;

proxy_set_header X-Forwarded-Protocol https;

#proxy_set_header X-Forwarded-HTTPS on;
            }
        }
    }
    '';

  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.extraUsers.matejc = {
    group = "users";
    extraGroups = [ "wheel" ];
    uid = 1000;
    createHome = true;
    home = "/home/matejc";
    shell = "/run/current-system/sw/bin/bash";
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOXEZu/ntHOrciyQMPl6kYUSz4+XUTBsl1mQINMA5mdcosaTOnBurjCh1HG5btGWV9Cjqy7OywC4LkgqEtjromD1YWeNfVTAk2kiG7tcNYYvWsxjJzdzH9t8H7eiLz8XM66Q+Ur7kilepw92wLValfAgr/SvnBzyo3/FfdN8MCuTe358dmKp5zvie3x9pzQ1tOwvVjkmW6tp2h/XKIsbEP4Hv4IbXcwPFAJGSlAr/CXnzNvprNW4tJmf0J9pm7Ovy9EyT/lHPhPZ+Ib91lngDZbjGQIl3Zf4XmkpVtfBjHUXnQlPZCThTMNBNcR97QP9IJFbptu/Bz8hGeFtz0ryxF matej@matej41"
    ];
  };
  users.extraUsers.zupo = {
    group = "users";
    extraGroups = [ "wheel" ];
    uid = 1001;
    createHome = true;
    home = "/home/zupo";
    shell = "/run/current-system/sw/bin/bash";
    openssh.authorizedKeys.keys = [
      "ssh-dss AAAAB3NzaC1kc3MAAACBALm52s2H3ZAWCkh1o4YENJtMgpCrBTR80Xw9wvIupg0k3/GDhLBm6Yxq849UMg5SzqpVYNt3IOk2mn0UAtPcCShKnlX0BQ/hiHeG2nd8FiPw48/5SXweAsd2wsU9225pvvdOOx2tsSpzmAL/yJ2MiDg9ucLzwaopwzusfiMxuva7AAAAFQC2Z1WGAVGZrlwbdart9ifJwwPqhwAAAIEArYRhMpz0eXoEIGCyb2e7e88WbYzm1a2Y/WniTJG9RZXsaXGvXnLHvhD/4R9casEJ/1tl5SGDaKVVi+ZbF7+muxfR9cHie9TfH5uNtOiEOhA6LHtkghfHUgg290KFIDMFI7YTdq2kCpGMOiQzTkMO9OvkfZAHt2vusS1cj9zPIXAAAACAdtcFh3IYhokkTOTGaHHwmi4LmIYwsnpPwg7TrQpiMQMJ3v/rnXAqFAxg6PcNjrenbcztPPNjKtxeeB1OFRun0ySw6YVYRp8ac5NfiEbdu1Q9ieuGwFb9BZbj+nmib1+3aPc/aFIHWol+dhD3YPymmuhMY7uMQ/g4mYbD+zhlmeA= zupo@Nejc-Zupans-MacBook-Pro.local"
    ];
  };

}
