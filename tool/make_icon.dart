import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  Directory('assets/icon').createSync(recursive: true);
  File('assets/icon/app_icon.png').writeAsBytesSync(img.encodePng(_icon(transparent: false)));
  File('assets/icon/app_icon_fg.png').writeAsBytesSync(img.encodePng(_icon(transparent: true)));
}

img.Image _icon({required bool transparent}) {
  final icon = img.Image(width: 1024, height: 1024, numChannels: 4);
  if (transparent) {
    img.fill(icon, color: img.ColorRgba8(0, 0, 0, 0));
  } else {
    img.fill(icon, color: img.ColorRgb8(47, 107, 255));
  }
  final page = transparent ? img.ColorRgba8(255, 255, 255, 255) : img.ColorRgb8(255, 255, 255);
  img.fillRect(icon, x1: 292, y1: 176, x2: 732, y2: 848, color: page, radius: 36);
  img.fillRect(icon, x1: 612, y1: 176, x2: 732, y2: 296, color: img.ColorRgb8(214, 226, 255), radius: 8);
  final ink = img.ColorRgb8(47, 107, 255);
  for (var y = 390; y <= 700; y += 78) {
    img.drawLine(icon, x1: 360, y1: y, x2: 650, y2: y, color: ink, thickness: 22);
  }
  img.fillRect(icon, x1: 360, y1: 748, x2: 520, y2: 792, color: img.ColorRgb8(227, 107, 44), radius: 12);
  return icon;
}
