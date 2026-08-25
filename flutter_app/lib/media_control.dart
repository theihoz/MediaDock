import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_control/controller_bootstrap.dart';
import 'package:media_control/unified_search_controller.dart';

part 'app/app_ui.dart';
part 'app/media_control_app.dart';
part 'app/media_shell.dart';
part 'core/api.dart';
part 'core/search_history.dart';
part 'features/discovery/discovery_page.dart';
part 'features/downloads/downloads_page.dart';
part 'features/library/library_page.dart';
part 'features/subtitles/subtitles_page.dart';
part 'features/system/system_pages.dart';
