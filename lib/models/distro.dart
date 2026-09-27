/// Định nghĩa 1 bản phân phối Linux có thể cài qua proot.
///
/// Mỗi distro có rootfs riêng biệt tại `<filesDir>/rootfs-<id>`, nên có thể
/// cài song song nhiều distro cùng lúc mà không đụng nhau.
class Distro {
  final String id; // khớp tên thư mục rootfs: rootfs-<id>
  final String displayName;
  final String description;

  /// abi ('arm64-v8a' | 'armeabi-v7a') -> URL tải tarball trực tiếp.
  /// Rỗng nếu distro cần resolve URL động (xem [gentooAutobuilds]).
  final Map<String, String> archUrls;

  /// true nếu tarball nén .tar.xz (cần XZDecoder), false = .tar.gz (gzip).
  final bool isXz;

  /// Đường dẫn (tương đối trong rootfs) dùng để nhận biết đã cài xong.
  final String markerFile;

  /// Ghi thêm vào log sau khi cài xong, nếu distro cần lưu ý gì thêm.
  final String? postInstallNote;

  /// Gentoo xoá các bản build cũ theo thời gian, và ngay cả symlink
  /// "current-stage3-*" (dùng ở bản trước) đôi khi 404 tuỳ mirror/route -
  /// nên thay vào đó ta tự quét thư mục autobuilds/ (luôn ổn định, không
  /// phải symlink) để tìm thư mục ngày-giờ MỚI NHẤT, rồi tự suy ra tên
  /// file thay vì phụ thuộc bất kỳ con trỏ "latest" nào của Gentoo.
  final Map<String, GentooAutobuild>? gentooAutobuilds;

  const Distro({
    required this.id,
    required this.displayName,
    required this.description,
    required this.archUrls,
    this.isXz = false,
    required this.markerFile,
    this.postInstallNote,
    this.gentooAutobuilds,
  });

  bool supportsAbi(String abi) =>
      archUrls.containsKey(abi) || (gentooAutobuilds?.containsKey(abi) ?? false);
}

/// Cấu hình để tự dò bản Gentoo stage3 mới nhất từ thư mục autobuilds/.
class GentooAutobuild {
  final String archPath; // 'arm64' | 'arm' - phần đường dẫn trong URL Gentoo
  final String profile;  // 'arm64-openrc' | 'armv7a-openrc' - phần tên trong file stage3

  const GentooAutobuild({required this.archPath, required this.profile});
}

class Distros {
  static const alpine = Distro(
    id: 'alpine',
    displayName: 'Alpine Linux',
    description: 'Siêu nhẹ (~8MB), dùng apk. Khởi động nhanh nhất, phù hợp '
        'máy yếu/ít bộ nhớ.',
    archUrls: {
      'arm64-v8a':
          'https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-minirootfs-3.19.9-aarch64.tar.gz',
      'armeabi-v7a':
          'https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/armv7/alpine-minirootfs-3.19.9-armv7.tar.gz',
    },
    markerFile: 'etc/alpine-release',
  );

  static const ubuntu = Distro(
    id: 'ubuntu',
    displayName: 'Ubuntu',
    description: 'Ubuntu Base 24.04 LTS (~28MB), dùng apt. Tương thích phần '
        'mềm/tài liệu hướng dẫn rộng rãi nhất.',
    archUrls: {
      'arm64-v8a':
          'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04.4/release/ubuntu-base-24.04.4-base-arm64.tar.gz',
      'armeabi-v7a':
          'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04.4/release/ubuntu-base-24.04.4-base-armhf.tar.gz',
    },
    markerFile: 'etc/os-release',
  );

  static const arch = Distro(
    id: 'arch',
    displayName: 'Arch Linux ARM',
    description: 'Rolling release, dùng pacman. LƯU Ý: tarball chính thức '
        '~800MB+ (kèm gói kernel không dùng tới trong proot).',
    archUrls: {
      'arm64-v8a': 'http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz',
      'armeabi-v7a': 'http://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz',
    },
    markerFile: 'etc/arch-release',
  );

  static const gentoo = Distro(
    id: 'gentoo',
    displayName: 'Gentoo',
    description: 'Stage3 OpenRC (~200-300MB, giải nén nặng hơn nhiều). Cần '
        'RAM rộng rãi lúc cài vì phải giải nén .tar.xz trong bộ nhớ.',
    archUrls: {},
    isXz: true,
    markerFile: 'etc/gentoo-release',
    gentooAutobuilds: {
      'arm64-v8a': GentooAutobuild(archPath: 'arm64', profile: 'arm64-openrc'),
      'armeabi-v7a': GentooAutobuild(archPath: 'arm', profile: 'armv7a-openrc'),
    },
    postInstallNote:
        '⚠️ Gentoo mới cài chỉ có stage3 gốc, CHƯA có portage tree (danh '
        'sách package). Chạy lệnh sau trong CLI trước khi dùng "emerge":\n'
        '  emerge-webrsync\n'
        '(lệnh này tải khá nặng và mất vài phút)',
  );

  static const all = [alpine, ubuntu, arch, gentoo];

  static Distro byId(String id) =>
      all.firstWhere((d) => d.id == id, orElse: () => alpine);
}