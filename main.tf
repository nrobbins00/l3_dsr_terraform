terraform {
  required_providers {
    external = {
      source = "hashicorp/external"
      #version = "20.1.4"
    }
    avi = {
      source = "vmware/avi"
      version = "20.1.4"
    }
    time = {
        source = "hashicorp/time"
    }
  }
}

provider "external" {}
provider "time" {}
provider "avi" {
    avi_username = var.avi_username
    avi_password =  var.avi_password
    avi_version = var.avi_version
    avi_tenant = var.avi_tenant
    avi_controller = var.avi_controller
}

data "avi_healthmonitor" "system_http" {
  name = "System-HTTP"
}

data "avi_network" "t2_portgroup" {
  name = var.t2_portgroup
}

data "avi_network" "t1_portgroup" {
  name = var.t1_portgroup
}

data "avi_vrfcontext" "front_end_vrf" {
  name = var.tier_1_vrf
}

data "avi_vrfcontext" "back_end_vrf" {
  name = var.tier_2_vrf
}

data "avi_tenant" "admin_tenant" {
  name = var.avi_tenant
}

data "avi_cloud" "vsphere_cloud" {
  name = var.avi_cloud
}
data "avi_applicationprofile" "l4_app" {
  name = "System-L4-Application"
}

data "avi_networkprofile" "l3_dsr" {
  name = "L3DSR"
}

resource "avi_serviceenginegroup" "tier_2_seg" {
  accelerated_networking = true
  algo = "PLACEMENT_ALGO_DISTRIBUTED"
  buffer_se = 0
  ha_mode = "HA_MODE_SHARED_PAIR"
  max_vs_per_se = 1
  min_scaleout_per_vs = 2
  name = "SEG-Tier-2"
  per_app = true
  realtime_se_metrics {
    enabled = false
  }
  se_dos_profile {
    thresh_period = 5
  }
  se_name_prefix = "T2Avi"
  tenant_ref = data.avi_tenant.admin_tenant.id
}


resource "avi_pool" "tier_2_pool" {
  cloud_ref = data.avi_cloud.vsphere_cloud.id
  health_monitor_refs = [data.avi_healthmonitor.system_http.id]
  name = "t2-vs2_pool"
  # networks = {
  #     network_ref = "https://localhost/api/vimgrnwruntime/dvportgroup-97-cloud-59713db1-0692-4043-934e-fa60d7a7b9df"
  # }
  servers {
    ip {
      addr = var.webserver1_ip
      type = "V4"
      }
    #"nw_ref" = "https://localhost/api/vimgrnwruntime/dvportgroup-97-cloud-59713db1-0692-4043-934e-fa60d7a7b9df"
    port = 80
  }
  servers {
    ip {
      addr = var.webserver2_ip
      type = "V4"
      }
    port = 80
  }
  tenant_ref = data.avi_tenant.admin_tenant.id
  vrf_ref = data.avi_vrfcontext.back_end_vrf.id
}


resource "avi_vsvip" "tier_2_vsvip" {
  cloud_ref = data.avi_cloud.vsphere_cloud.id
  name = "vsvip-T2-VS-Default-Cloud"
  tenant_ref = data.avi_tenant.admin_tenant.id
  vip {
    ip_address {
      addr = var.vs_ip
      type = "V4"
    }
    placement_networks {
      network_ref = data.avi_network.t2_portgroup.id
      subnet {
        ip_addr {
          addr = var.server_subnet
          type = "V4"
        }
        mask = var.server_subnet_mask
      }
    }
  vip_id = 1
  }
  vrf_context_ref = data.avi_vrfcontext.back_end_vrf.id
}




resource "avi_virtualservice" "tier_2_vs" {
  cloud_ref = data.avi_cloud.vsphere_cloud.id
  analytics_policy {
    all_headers = true
    full_client_logs {
      duration= 0
      enabled = true
    }
    metrics_realtime_update {
      duration = 0
      enabled = true
    }
  }
  cloud_type = "CLOUD_VCENTER"
  enable_autogw = false
  name = "T2-VS"
  pool_ref = avi_pool.tier_2_pool.id
  se_group_ref = avi_serviceenginegroup.tier_2_seg.id
  services {
    port = 80
    port_range_end = 80
  }
  tenant_ref = data.avi_tenant.admin_tenant.id
  traffic_enabled = false
  vrf_context_ref = data.avi_vrfcontext.back_end_vrf.id
  vsvip_ref = avi_vsvip.tier_2_vsvip.id
}


resource "time_sleep" "wait_300_seconds" {
  depends_on = [avi_virtualservice.tier_2_vs]

  create_duration = "300s"
}

data "external" "se_ip_addresses" {
  depends_on = [time_sleep.wait_300_seconds]
  program = ["python", "getruntime.py"]

  query = {
    user = var.avi_username
    password = var.avi_password
    controller = var.avi_controller
    vs_name = "T2-VS"
  }
}


#data.external.se_ip_addresses.result.se0


output "se_interfaces" {
    value = data.external.se_ip_addresses.result.se0
}

resource "avi_serviceenginegroup" "tier_1_seg" {
  depends_on = [data.external.se_ip_addresses]
  accelerated_networking = true
  algo = "PLACEMENT_ALGO_DISTRIBUTED"
  buffer_se = 0
  ha_mode = "HA_MODE_SHARED_PAIR"
  max_vs_per_se = 1
  min_scaleout_per_vs = 2
  name = "SEG-Tier-1"
  per_app = true
  realtime_se_metrics {
    enabled = false
  }
  se_dos_profile {
    thresh_period = 5
  }
  se_name_prefix = "T1Avi"
  tenant_ref = data.avi_tenant.admin_tenant.id
}


resource "avi_pool" "tier_1_pool" {
  cloud_ref = data.avi_cloud.vsphere_cloud.id
  health_monitor_refs = [data.avi_healthmonitor.system_http.id]
  fail_action {
    type = "FAIL_ACTION_CLOSE_CONN"
  }
  lb_algorithm = "LB_ALGORITHM_CONSISTENT_HASH"
  name = "T1-VS-pool"
  placement_networks {
    network_ref = data.avi_network.t2_portgroup.id
    subnet {
      ip_addr {
        addr = var.server_subnet
        type = "V4"
      }
      mask = var.server_subnet_mask
    }
  }
  server_reselect {
    enabled = false
  }
  servers {
    hostname = data.external.se_ip_addresses.result.se0
    ip {
      addr = data.external.se_ip_addresses.result.se0
      type = "V4"
    }
  }
  servers {
    hostname = data.external.se_ip_addresses.result.se1
    ip {
      addr = data.external.se_ip_addresses.result.se1
      type = "V4"
    }
  }
  tenant_ref = data.avi_tenant.admin_tenant.id
  vrf_ref = data.avi_vrfcontext.front_end_vrf.id
}

resource "avi_vsvip" "tier_1_vsvip" {
  cloud_ref = data.avi_cloud.vsphere_cloud.id
  name = "vsvip-T1-VS-Default-Cloud"
  tenant_ref = data.avi_tenant.admin_tenant.id
  vip {
    ip_address {
      addr = var.vs_ip
      type = "V4"
    }
    placement_networks {
      network_ref = data.avi_network.t1_portgroup.id
      subnet {
        ip_addr {
          addr = var.front_end_subnet
          type = "V4"
        }
        mask = var.front_end_subnet_mask
      }
    }
    vip_id = 1
  }
  vrf_context_ref = data.avi_vrfcontext.front_end_vrf.id
}

resource "avi_virtualservice" "tier_1_vs" {
  cloud_ref = data.avi_cloud.vsphere_cloud.id
  analytics_policy {
    all_headers = true
    full_client_logs {
      duration = 0
      enabled = true
    }
    metrics_realtime_update {
      duration = 0
      enabled = false
      }
  }
  application_profile_ref = data.avi_applicationprofile.l4_app.id
  cloud_type = "CLOUD_VCENTER"
  name = "T1-VS"
  network_profile_ref = data.avi_networkprofile.l3_dsr.id
  pool_ref = avi_pool.tier_1_pool.id
  se_group_ref = avi_serviceenginegroup.tier_1_seg.id
  services {
    port = 80
    port_range_end = 80
  }
  tenant_ref = data.avi_tenant.admin_tenant.id
  vrf_context_ref = data.avi_vrfcontext.front_end_vrf.id
  vsvip_ref = avi_vsvip.tier_1_vsvip.id
}