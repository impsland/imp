//! This computer's addresses, ordered for a linking code.

use std::net::{IpAddr, Ipv4Addr};

/// One IPv4 address of one network interface of this computer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetworkAddress {
    /// The interface's name, such as en0, wlan0, utun3 or docker0.
    pub interface: String,
    pub address: Ipv4Addr,
    /// A point-to-point link, which is what VPN tunnels are.
    pub point_to_point: bool,
}

/// How likely a device on the same Wi-Fi is to reach an address. The best comes first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Reach {
    /// Wi-Fi or Ethernet with a private address (192.168.x.x, 10.x.x.x, 172.16-31.x.x): the home or office network.
    LocalNetwork,
    /// Wi-Fi or Ethernet with a public address.
    Public,
    /// A VPN tunnel. Only devices on the same VPN reach it.
    Tunnel,
    /// A bridge for containers or virtual machines. Only they reach it.
    Virtual,
}

/// Interface names that VPNs use (macOS utun and ipsec, Linux tun and wg, Tailscale, ZeroTier, and others).
const TUNNEL_INTERFACES: &[&str] = &[
    "utun",
    "tun",
    "tap",
    "wg",
    "ppp",
    "ipsec",
    "gif",
    "stf",
    "tailscale",
    "zt",
    "nordlynx",
];
/// Interface names of bridges for containers and virtual machines.
const VIRTUAL_INTERFACES: &[&str] = &[
    "docker",
    "br-",
    "veth",
    "virbr",
    "vmnet",
    "vboxnet",
    "bridge",
    "vnic",
    "lxc",
    "lxd",
    "cni",
    "flannel",
    "podman",
    "vethernet",
];

impl NetworkAddress {
    /// None for an address no other device can use: loopback, link-local (169.254.x.x) and the like.
    fn reach(&self) -> Option<Reach> {
        let a = self.address;
        if a.is_loopback()
            || a.is_unspecified()
            || a.is_link_local()
            || a.is_multicast()
            || a.is_broadcast()
        {
            return None;
        }
        let name = self.interface.to_ascii_lowercase();
        let named = |prefixes: &[&str]| prefixes.iter().any(|p| name.starts_with(p));
        Some(if self.point_to_point || named(TUNNEL_INTERFACES) {
            Reach::Tunnel
        } else if named(VIRTUAL_INTERFACES) {
            Reach::Virtual
        } else if a.is_private() {
            Reach::LocalNetwork
        } else {
            Reach::Public
        })
    }
}

/// The addresses other devices can use to reach this computer, best first, for a linking code.
///
/// A phone on the same Wi-Fi needs the address this computer has on that network. So Wi-Fi and Ethernet
/// come first, then VPN tunnels, then bridges for containers and virtual machines. The address the
/// system would use to go out to the internet leads its group. On its own it is not enough: with a VPN
/// that carries all traffic it is the tunnel's address, which a phone on the Wi-Fi cannot reach.
pub fn local_hosts() -> Vec<String> {
    let addresses = if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter(|i| i.oper_status != if_addrs::IfOperStatus::Down)
        .filter_map(|i| match i.ip() {
            IpAddr::V4(address) => Some(NetworkAddress {
                point_to_point: i.is_p2p(),
                interface: i.name,
                address,
            }),
            IpAddr::V6(_) => None,
        })
        .collect::<Vec<_>>();
    order_hosts(&addresses, outgoing_address())
}

/// Orders the addresses for a linking code, as `local_hosts` describes, without repeats and at most as
/// many as a code holds. `outgoing` is the address the system uses to go out. It is added when no
/// interface lists it, which happens where interfaces cannot be read.
pub fn order_hosts(addresses: &[NetworkAddress], outgoing: Option<Ipv4Addr>) -> Vec<String> {
    let mut all = addresses.to_vec();
    if let Some(address) = outgoing.filter(|a| !all.iter().any(|n| n.address == *a)) {
        all.push(NetworkAddress {
            interface: String::new(),
            address,
            point_to_point: false,
        });
    }
    let mut ranked = all
        .iter()
        .filter_map(|n| {
            n.reach()
                .map(|reach| (reach, Some(n.address) != outgoing, n.address))
        })
        .collect::<Vec<_>>();
    // A stable sort, so addresses of the same kind keep the order the system lists them in.
    ranked.sort_by_key(|&(reach, not_outgoing, _)| (reach, not_outgoing));
    let mut hosts = Vec::<String>::new();
    for (_, _, address) in ranked {
        let host = address.to_string();
        if !hosts.contains(&host) {
            hosts.push(host);
        }
    }
    hosts.truncate(imp_engine::link::card::MOST_HOSTS);
    hosts
}

/// The address the system would use to go out to the internet. Nothing is sent: connecting a UDP
/// socket only picks the route.
fn outgoing_address() -> Option<Ipv4Addr> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("192.0.2.1:9").ok()?;
    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(address) => Some(address),
        IpAddr::V6(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(interface: &str, address: &str, point_to_point: bool) -> NetworkAddress {
        NetworkAddress {
            interface: interface.into(),
            address: address.parse().unwrap(),
            point_to_point,
        }
    }

    #[test]
    fn wifi_comes_before_a_vpn_that_carries_all_traffic() {
        // The VPN tunnel is the way out, but a phone on the Wi-Fi can only use the Wi-Fi address.
        let addresses = [
            at("en0", "192.168.68.53", false),
            at("utun6", "10.2.0.2", true),
        ];
        let outgoing = Some("10.2.0.2".parse().unwrap());
        assert_eq!(
            order_hosts(&addresses, outgoing),
            ["192.168.68.53", "10.2.0.2"]
        );
    }

    #[test]
    fn tunnels_are_known_by_name_too_and_bridges_come_last() {
        let addresses = [
            at("docker0", "172.17.0.1", false),
            at("tailscale0", "100.101.102.103", false),
            at("lo", "127.0.0.1", false),
            at("en0", "169.254.10.20", false),
            at("wlan0", "10.0.0.7", false),
        ];
        assert_eq!(
            order_hosts(&addresses, None),
            ["10.0.0.7", "100.101.102.103", "172.17.0.1"]
        );
    }

    #[test]
    fn the_way_out_leads_its_group_and_nothing_repeats() {
        let addresses = [
            at("en0", "192.168.1.5", false),
            at("en1", "10.0.0.7", false),
            at("en1", "10.0.0.7", false),
            at("en2", "203.0.113.9", false),
        ];
        let outgoing = Some("10.0.0.7".parse().unwrap());
        assert_eq!(
            order_hosts(&addresses, outgoing),
            ["10.0.0.7", "192.168.1.5", "203.0.113.9"]
        );
    }

    #[test]
    fn without_interfaces_the_way_out_is_used() {
        assert_eq!(
            order_hosts(&[], Some("192.168.1.9".parse().unwrap())),
            ["192.168.1.9"]
        );
        assert_eq!(
            order_hosts(&[], Some("127.0.0.1".parse().unwrap())),
            Vec::<String>::new()
        );
        assert!(order_hosts(&[], None).is_empty());
    }

    #[test]
    fn a_code_holds_only_so_many_hosts() {
        let many = (1..=20)
            .map(|n| at("en0", &format!("192.168.1.{n}"), false))
            .collect::<Vec<_>>();
        let hosts = order_hosts(&many, None);
        assert_eq!(hosts.len(), imp_engine::link::card::MOST_HOSTS);
        assert_eq!(hosts[0], "192.168.1.1");
    }
}
