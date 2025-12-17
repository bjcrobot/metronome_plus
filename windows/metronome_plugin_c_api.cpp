#include "include/metronome_plus/metronome_plus_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "metronome_plugin.h"

void MetronomePlusPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  metronome::MetronomePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
