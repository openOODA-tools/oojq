Name:           oojq
Version:        0.1.1
Release:        1%{?dist}
Summary:        Capability-bounded jq replacement with stdio MCP
License:        ASL 2.0
URL:            https://github.com/openOODA-tools/oojq
Source0:        oojq-linux-x86_64
Source1:        uninstall.sh
BuildArch:      x86_64
Requires:       glibc

%description
oojq is a capability-bounded jq replacement written in 100% openOODA,
delivering 98% jq parity, exact arithmetic, clean uninstaller, and an
agent-native MCP server over stdio.

%install
mkdir -p %{buildroot}/usr/bin
install -m 0755 %{SOURCE0} %{buildroot}/usr/bin/oojq
install -m 0755 %{SOURCE1} %{buildroot}/usr/bin/oojq-uninstall

%files
/usr/bin/oojq
/usr/bin/oojq-uninstall

%changelog
* Tue Oct 06 2026 openOODA-tools <ops@openooda.org> - 0.1.1-1
- Align AGENTS.md, companion uninstaller (oojq-uninstall), oote theme integration, and packaging
* Mon Oct 05 2026 openOODA-tools <ops@openooda.org> - 0.1.0-1
- Initial sovereign release: 98% jq parity, hardened defenses, universal installers (web, dnf, apt), and green CI/CD
