%global _lto_cflags %{nil}

Name:           kogaview
Version:        2.0.0
Release:        1%{?dist}
Summary:        Fast native desktop photo manager, viewer, and non-destructive editor
License:        MIT
URL:            https://github.com/tienv2i/kogaview
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  cmake >= 3.24
BuildRequires:  ninja-build
BuildRequires:  pkgconf-pkg-config
BuildRequires:  gcc-c++
BuildRequires:  rust
BuildRequires:  cargo
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt6-qtdeclarative-devel
BuildRequires:  qt6-qtsvg-devel
BuildRequires:  qt6-linguist
BuildRequires:  libdav1d-devel
BuildRequires:  python3

Requires:       qt6-qtbase
Requires:       qt6-qtdeclarative
Requires:       qt6-qtsvg
Requires:       libdav1d

%description
KogaView is a fast, native desktop photo manager, viewer, and non-destructive
image editor built with Rust and Qt 6 / QML via CXX-Qt.

%prep
%autosetup

%build
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DKOGAVIEW_BUILD_TESTS=OFF -DCMAKE_INSTALL_PREFIX=%{_prefix}
cmake --build build --target kogaview kogaview_translations

%install
install -Dm755 build/bin/kogaview %{buildroot}%{_bindir}/kogaview
install -Dm644 packaging/linux/io.github.tienv2i.KogaView.metainfo.xml %{buildroot}%{_metainfodir}/io.github.tienv2i.KogaView.metainfo.xml
install -Dm644 packaging/linux/io.github.tienv2i.KogaView.svg %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/io.github.tienv2i.KogaView.svg
install -Dm644 LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%license LICENSE
%{_bindir}/kogaview
%{_metainfodir}/io.github.tienv2i.KogaView.metainfo.xml
%{_datadir}/icons/hicolor/scalable/apps/io.github.tienv2i.KogaView.svg

%changelog
* Tue Nov 24 2026 KogaView Contributors - 1.2.0-1
- Release 1.2.0 (1-by-1 progressive toolbar folding, synced & persisted Compact HUD, Simple-mode sidebar & filmstrip toggles, shared Editor DimensionRatioGrid)

* Tue Nov 24 2026 KogaView Contributors - 1.1.0-1
- Release 1.1.0 (Viewer modes, Dual/Webtoon readers, Fullscreen, 4-edge Compact HUD)

* Mon Nov 23 2026 KogaView Contributors - 1.0.0-1
- Release 1.0.0
