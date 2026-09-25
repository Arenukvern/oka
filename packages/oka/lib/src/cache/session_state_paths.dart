import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Resolves a registered directory resource only when its persisted path is
/// absolute and traversal-free. Invalid leases must never become deletion
/// authority.
String? sessionStateDirectoryPath(SessionStateLease lease) {
  if (lease.phase == SessionStatePhase.disposed ||
      lease.resourceKind != SessionStateResourceKind.directory) {
    return null;
  }
  final root = lease.rootPath;
  final relative = lease.relativePath;
  if (!p.isAbsolute(root) ||
      relative.isEmpty ||
      relative == '.' ||
      relative == '..' ||
      relative.startsWith('/') ||
      relative.contains(r'\') ||
      relative.split('/').contains('..')) {
    return null;
  }
  final absoluteRoot = p.normalize(root);
  final resource = p.normalize(p.join(absoluteRoot, relative));
  if (!p.isWithin(absoluteRoot, resource)) return null;
  return resource;
}

/// Resolves the project-local durable reservation marker only for a valid
/// directory lease. Cache cleanup must protect it as well as the resource.
String? sessionStateReservationMarkerPath(SessionStateLease lease) {
  if (sessionStateDirectoryPath(lease) == null ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(lease.id)) {
    return null;
  }
  final root = p.normalize(lease.rootPath);
  final marker = p.normalize(lease.reservationMarkerPath);
  if (!p.isWithin(root, marker)) return null;
  return marker;
}

/// Resolves a lease's persisted in-progress deletion path only when it is
/// contained by the recorded root and no component currently traverses a
/// symbolic link. The registry is untrusted input; an unsafe path must disable
/// cleanup rather than become deletion authority.
Future<String?> sessionStateQuarantinePath(SessionStateLease lease) async {
  final relative = lease.quarantineRelativePath;
  if (lease.phase == SessionStatePhase.disposed ||
      lease.resourceKind != SessionStateResourceKind.directory ||
      relative == null ||
      relative.isEmpty ||
      relative.startsWith('/') ||
      relative.contains(r'\') ||
      p.isAbsolute(relative) ||
      relative
          .split('/')
          .any(
            (component) =>
                component.isEmpty || component == '.' || component == '..',
          )) {
    return null;
  }

  final root = p.normalize(lease.rootPath);
  if (!p.isAbsolute(root)) return null;
  final path = p.normalize(p.join(root, relative));
  if (!p.isWithin(root, path)) return null;

  // Check the root and every component beneath it. Missing components are
  // allowed so a persisted quarantine remains protected before it exists. If
  // any existing component is a link (or cannot be inspected), fail closed.
  var current = path;
  try {
    while (true) {
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        return null;
      }
      if (p.equals(current, root)) break;
      final parent = p.dirname(current);
      if (parent == current ||
          (!p.equals(parent, root) && !p.isWithin(root, parent))) {
        return null;
      }
      current = parent;
    }
  } on Object {
    return null;
  }
  return path;
}

bool sessionStateResourceIsWithin(String directory, String resource) {
  final root = p.normalize(p.absolute(directory));
  final path = p.normalize(p.absolute(resource));
  return p.equals(root, path) || p.isWithin(root, path);
}
