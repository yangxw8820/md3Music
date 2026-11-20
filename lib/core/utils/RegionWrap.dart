import 'package:dpad/dpad.dart';
import 'package:flutter/cupertino.dart';

import '../build_flags.dart';

extension RegionWidget on Widget {
  Widget wrap({String? debugLabel}) {
    if (!kTvBuild) return this;
    return DpadRegion(
      memoryKey: debugLabel != null ? 'tv/$debugLabel' : null,
      debugLabel: debugLabel,
      child: this,
    );
  }

  Widget wrapFocus({bool autofocus = true}) {
    if (!kTvBuild) return this;

    void Function()? onSelect;
    if (this is GestureDetector) {
      onSelect = () {
        (this as GestureDetector).onTap?.call();
      };
    }
    return DpadFocusable(autofocus: autofocus, onSelect: onSelect, child: this);
  }
}
