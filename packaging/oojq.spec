Name:           oojq
Version:        0.1.0
Release:        1%{?dist}
Summary:        Capability-bounded jq replacement with stdio MCP
License:        ASL 2.0
URL:            https://github.com/openOODA-tools/oojq
Source0:        oojq-linux-x86_64
BuildArch:      x86_64
Requires:       glibc

%description
oojq is a capability-bounded jq replacement written in 100% openOODA,
delivering 98% jq parity, exact arithmetic, and an agent-native MCP
server over stdio.

%install
mkdir -p %{buildroot}/usr/bin
install -m 0755 %{SOURCE0} %{buildroot}/usr/bin/oojq

%files
/usr/bin/oojq

%changelog
* Mon Oct 05 2026 openOODA-tools <ops@openooda.org> - 0.1.0-1
- Initial sovereign release: 98% jq parity, hardened defenses, universal installers (web, dnf, apt), and green CI/CD
