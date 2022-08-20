
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.4.3"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 2.16.0"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
      version = "3.20.0"
    }
  }
}

variable "docker_host" {
  description = "Specify location of Docker socket (check `docker context ls` if you're not sure)"
  sensitive   = true
}

variable "docker_arch" {
  description = "Specify architecture of docker host (amd64, arm64, or armv7)"
  validation {
    condition     = contains(["amd64", "arm64", "armv7"], var.docker_arch)
    error_message = "Value must be amd64, arm64, or armv7."
  }
  sensitive = true
}

provider "cloudflare" {
  api_token = "{{CLOUDFLARE_API_TOKEN}}"
}

variable "cf_zone_id" {
  default = "{CLOUDFLARE_ZONE_ID}"
}

variable "cf_domain" {
  default = "{DOMAIN.COM}"
}

variable "cf_account_id" {
  default = "{CLOUDFLARE_ACCOUNT_ID}"
}

provider "coder" {
}

provider "docker" {
  host = var.docker_host
}

data "coder_workspace" "me" {
}

resource "coder_agent" "main" {
  arch           = var.docker_arch
  os             = "linux"
  startup_script = <<EOT
    #!/bin/bash

    # install code-server
    curl -fsSL https://code-server.dev/install.sh | sh

    # The & prevents the startup_script from blocking so the
    # next commands can run.
    code-server --auth none --port 8080 &
    echo "alias code='/usr/bin/code-server'" >> $HOME/.bashrc

    # install cloudflared
    sudo rm -R ~/.cloudflared
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    sudo dpkg -i cloudflared.deb
    rm cloudflared.deb
    mkdir ~/.cloudflared
    touch ~/.cloudflared/config.yaml
    touch ~/.cloudflared/cert.json
    echo "{\"AccountTag\":\"${var.cf_account_id}\",\"TunnelID\":\"${cloudflare_argo_tunnel.agtunnel.id}\",\"TunnelName\":\"${lower(data.coder_workspace.me.name)}-tunnel\",\"TunnelSecret\":\"${random_id.argo_secret.b64_std}\"}" >> ~/.cloudflared/cert.json
    echo "  tunnel: ${cloudflare_argo_tunnel.agtunnel.id}" >> ~/.cloudflared/config.yaml
    echo "  credentials-file: /home/coder/.cloudflared/cert.json" >> ~/.cloudflared/config.yaml
    echo "  loglevel: info" >> ~/.cloudflared/config.yaml
    echo "  ingress:" >> ~/.cloudflared/config.yaml
    echo "    - hostname: 5000.${lower(data.coder_workspace.me.name)}.{{DOMAIN.COM}}" >> ~/.cloudflared/config.yaml
    echo "      service: http://localhost:5000" >> ~/.cloudflared/config.yaml
    echo "    - hostname: \"*\"" >> ~/.cloudflared/config.yaml
    echo "      service: http_status:404" >> ~/.cloudflared/config.yaml
  
    sudo cloudflared --config /home/coder/.cloudflared/config.yaml service install
    sudo cloudflared service start

  EOT

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  # You can remove this block if you prefer to configure Git manually or using
  # dotfiles. (see docs/dotfiles.md)
  env = {
    GIT_AUTHOR_NAME = "${data.coder_workspace.me.owner}"
    GIT_COMMITTER_NAME = "${data.coder_workspace.me.owner}"
    GIT_AUTHOR_EMAIL = "${data.coder_workspace.me.owner_email}"
    GIT_COMMITTER_EMAIL = "${data.coder_workspace.me.owner_email}"
  }
}

resource "coder_app" "code-server" {
  agent_id = coder_agent.main.id
  url      = "http://localhost:8080/?folder=/home/coder"
  icon     = "/icon/code.svg"
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}-root"
}

resource "random_id" "argo_secret" {
  byte_length = 35
}

resource "cloudflare_argo_tunnel" "agtunnel" {
  account_id = var.cf_account_id
  name       = "${lower(data.coder_workspace.me.name)}-tunnel"
  secret     = random_id.argo_secret.b64_std
}

resource "cloudflare_certificate_pack" "agtunnel-cert" {
  zone_id               = var.cf_zone_id
  type                  = "advanced"
  hosts                 = ["*.${lower(data.coder_workspace.me.name)}.{{DOMAIN.COM}}"]
  validation_method     = "txt"
  validity_days         = 30
  certificate_authority = "digicert"
  cloudflare_branding   = false
}

resource "cloudflare_record" "agtunnel" {
  zone_id = var.cf_zone_id
  name    = "*.${lower(data.coder_workspace.me.name)}"
  value   = cloudflare_argo_tunnel.agtunnel.cname
  type    = "CNAME"
  proxied = true
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = "codercom/enterprise-node:ubuntu"
  # Uses lower() to avoid Docker restriction on container names.
  name     = "coder-${data.coder_workspace.me.owner}-${lower(data.coder_workspace.me.name)}"
  hostname = lower(data.coder_workspace.me.name)
  dns      = ["1.1.1.1"]
  # Use the docker gateway if the access URL is 127.0.0.1
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "127.0.0.1", "host.docker.internal")]
  env        = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  volumes {
    container_path = "/home/coder/"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }
}