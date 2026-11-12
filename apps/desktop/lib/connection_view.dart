import 'package:flutter/material.dart';
import 'ui_palette.dart';
import 'workspace/library_widgets.dart';

/// Shared presentation for connection, recovery and loading. Network and
/// profile decisions stay in the launcher; no preview values are supplied here.
class ConnectionSurface extends StatelessWidget {
  const ConnectionSurface({
    super.key,
    required this.title,
    required this.description,
    required this.children,
    this.icon = Icons.dns_outlined,
    this.loading = false,
    this.embedded = false,
  });
  final String title, description;
  final List<Widget> children;
  final IconData icon;
  final bool loading, embedded;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return ColoredBox(
      color: c.rail,
      child: SafeArea(
        child: Align(
          alignment: embedded ? Alignment.topLeft : Alignment.center,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: SizedBox(
              width: 480,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: c.selected,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: loading
                          ? SizedBox(
                              width: 30,
                              height: 30,
                              child: CircularProgressIndicator(
                                color: c.accent,
                                strokeWidth: 2,
                              ),
                            )
                          : Icon(icon, color: c.accent, size: 30),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(title, style: libraryHeading(context, 28)),
                  const SizedBox(height: 10),
                  Text(
                    description,
                    style: libraryText(
                      context,
                      14,
                      color: c.muted,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 28),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
