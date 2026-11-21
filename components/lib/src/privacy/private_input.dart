import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Text input that does not hand what the user types to other apps or services.
///
/// A normal text field lets the keyboard app learn from the text (suggestions,
/// autocorrect, personalised learning), the spell checker service read it,
/// password managers try to autofill it, and the selection menu offer to share
/// it or send it to other apps. Messages, group names and nicknames are exactly
/// what must not leak that way.
abstract final class PrivateInput {
  /// Selection menu limited to editing actions: no Share, Translate, Look Up,
  /// Search web or other apps' actions.
  static const allowedMenuItems = {
    ContextMenuButtonType.cut,
    ContextMenuButtonType.copy,
    ContextMenuButtonType.paste,
    ContextMenuButtonType.selectAll,
  };

  static List<ContextMenuButtonItem> filterMenu(List<ContextMenuButtonItem> items) =>
      items.where((item) => allowedMenuItems.contains(item.type)).toList();

  static Widget contextMenu(BuildContext context, EditableTextState state) {
    final items = filterMenu(state.contextMenuButtonItems);
    if (items.isEmpty) return const SizedBox.shrink();
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: items);
  }
}

/// A [TextField] with [PrivateInput]'s protections always on.
class PrivateTextField extends StatelessWidget {
  const PrivateTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.autofocus = false,
    this.enabled,
    this.minLines,
    this.maxLines = 1,
    this.maxLength,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.decoration,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool? enabled;
  final int? minLines;
  final int? maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final InputDecoration? decoration;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final GestureTapCallback? onTap;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    focusNode: focusNode,
    autofocus: autofocus,
    enabled: enabled,
    minLines: minLines,
    maxLines: maxLines,
    maxLength: maxLength,
    keyboardType: keyboardType,
    textInputAction: textInputAction,
    textCapitalization: textCapitalization,
    decoration: decoration,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    onTap: onTap,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
    autofillHints: const <String>[],
    contextMenuBuilder: PrivateInput.contextMenu,
  );
}

/// A [TextFormField] with [PrivateInput]'s protections always on.
class PrivateTextFormField extends StatelessWidget {
  const PrivateTextFormField({
    super.key,
    this.controller,
    this.maxLength,
    this.decoration,
    this.validator,
    this.textInputAction,
    this.onChanged,
  });

  final TextEditingController? controller;
  final int? maxLength;
  final InputDecoration? decoration;
  final FormFieldValidator<String>? validator;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    maxLength: maxLength,
    decoration: decoration,
    validator: validator,
    textInputAction: textInputAction,
    onChanged: onChanged,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
    autofillHints: const <String>[],
    contextMenuBuilder: PrivateInput.contextMenu,
  );
}
