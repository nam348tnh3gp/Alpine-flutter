/// Định nghĩa 1 bản phân phối Linux có thể cài qua proot.
///
/// Mỗi distro có rootfs riêng biệt tại `<filesDir>/rootfs-<id>`, nên có thể
/// cài song song nhiều distro cùng lúc mà không đụng nhau.
class Distro {
  final String id; // khớp tên thư mục rootfs: rootfs-<id>
  final String displayName;
  final String description;

  /// abi ('arm64-v8a' | 'armeabi-v7a') -> URL tải tarball trực tiếp.
  /// Rỗng nếu distro cần resolve URL động (xem [gentooAutobuilds],
  /// [alpineLatest]).
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

  /// Alpine cũng xoá dần các bản minirootfs point-release cũ khỏi mirror
  /// (vd URL trỏ cứng tới 3.19.9 sẽ 404 khi 3.19.9 bị bỏ). Vì vậy ta
  /// resolve URL động qua `latest-releases.yaml` của branch stable.
  final Map<String, AlpineLatest>? alpineLatest;

  const Distro({
    required this.id,
    required this.displayName,
    required this.description,
    required this.archUrls,
    this.isXz = false,
    required this.markerFile,
    this.postInstallNote,
    this.gentooAutobuilds,
    this.alpineLatest,
  });

  bool supportsAbi(String abi) =>
      archUrls.containsKey(abi) ||
      (gentooAutobuilds?.containsKey(abi) ?? false) ||
      (alpineLatest?.containsKey(abi) ?? false);
}

/// Cấu hình để tự dò bản Gentoo stage3 mới nhất từ thư mục autobuilds/.
class GentooAutobuild {
  final String archPath;   // 'arm64' | 'arm'
  final String profile;    // 'arm64-openrc' | 'armv7a_hardfp-t64-openrc'
  final String latestFile; // tên file latest-stage3-*.txt

  const GentooAutobuild({
    required this.archPath,
    required this.profile,
    required this.latestFile,
  });

  /// URL đầy đủ đến file latest-stage3-*.txt
  String get latestUrl =>
      'https://distfiles.gentoo.org/releases/$archPath/autobuilds/'
      'current-stage3-$profile/$latestFile';

  /// Thư mục chứa tarball (dùng để ghép URL sau khi đọc tên file).
  String get tarballBaseUrl =>
      'https://distfiles.gentoo.org/releases/$archPath/autobuilds/'
      'current-stage3-$profile/';
}

/// Cấu hình để tự dò bản Alpine minirootfs mới nhất.
///
/// LÝ DO: URL kiểu cũ
///   .../alpine/v3.19/releases/aarch64/alpine-minirootfs-3.19.9-aarch64.tar.gz
/// trỏ cứng vào 1 point-release cụ thể. Khi Alpine ra bản mới và xoá bản cũ
/// khỏi mirror, URL trả 404 → app thử tải lại nhiều lần → "bug phải tải lại
/// rootfs của Alpine". Giải pháp: đọc `latest-releases.yaml` (Alpine duy trì
/// ổn định tại mỗi branch) và lấy tên file minirootfs mới nhất.
class AlpineLatest {
  /// Nhánh stable ('latest-stable', 'v3.20', 'v3.21', ...).
  final String branch;
  /// Tên kiến trúc trong URL Alpine ('aarch64' | 'armv7' | 'x86_64' ...).
  final String arch;
  /// Loại rootfs cần tải (mặc định 'minirootfs').
  final String variant;

  const AlpineLatest({
    required this.branch,
    required this.arch,
    this.variant = 'minirootfs',
  });

  String get baseUrl =>
      'https://dl-cdn.alpinelinux.org/alpine/$branch/releases/$arch/';

  /// File YAML liệt kê các bản release mới nhất của branch.
  String get yamlUrl => '${baseUrl}latest-releases.yaml';
}

class Distros {
  /// Alpine: URL resolve động qua latest-releases.yaml → không còn 404 khi
  /// Alpine xoá point-release cũ, hết cảnh "phải tải lại rootfs".
  static const alpine = Distro(
    id: 'alpine',
    displayName: 'Alpine Linux',
    description: 'Siêu nhẹ (~8MB), dùng apk. Khởi động nhanh nhất, phù hợp '
        'máy yếu/ít bộ nhớ.',
    archUrls: {}, // resolve động qua alpineLatest
    markerFile: 'etc/alpine-release',
    alpineLatest: {
      'arm64-v8a': AlpineLatest(
        branch: 'latest-stable',
        arch: 'aarch64',
      ),
      'armeabi-v7a': AlpineLatest(
        branch: 'latest-stable',
        arch: 'armv7',
      ),
    },
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

  // ✅ FIX: đổi http:// -> https:// để tránh bị Android 9+ chặn cleartext
  static const arch = Distro(
    id: 'arch',
    displayName: 'Arch Linux ARM',
    description: 'Rolling release, dùng pacman. LƯU Ý: tarball chính thức '
        '~800MB+ (kèm gói kernel không dùng tới trong proot).',
    archUrls: {
      'arm64-v8a':
          'https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz',
      'armeabi-v7a':
          'https://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz',
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
      'arm64-v8a': GentooAutobuild(
        archPath: 'arm64',
        profile: 'arm64-openrc',
        latestFile: 'latest-stage3-arm64-openrc.txt',
      ),
      'armeabi-v7a': GentooAutobuild(
        archPath: 'arm',
        profile: 'armv7a_hardfp-t64-openrc',
        latestFile: 'latest-stage3-armv7a_hardfp-t64-openrc.txt',
      ),
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