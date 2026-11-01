// home.dart

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/api_service.dart';
import 'services/recorder_service.dart';
import 'widgets/connectivity_card.dart';
import 'dart:async';
import 'dart:typed_data';
import 'services/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/*
===============================================================================
                                    SECTIONS
===============================================================================

1. VARIABLES .................................................................. Line 34
   - variables used throughout the class

2. INITIALIZATION ............................................................. Line 54
   - initState()
   - _initializeUser()
   - _loadLastSelectedChannel()
   - _openRecorder()

3. EVENT LISTENERS ............................................................ Line 98
   - _setupEventListener()
   - _setupAudioStreamListener()

4. RECORDER METHODS ........................................................... Line 153
   - _startStreaming()
   - _stopStreaming()

5. API CALLS .................................................................. Line 169
   - _fetchChannels()
   - _connect()
   - _disconnect()
   - _createChannel()
   - _joinChannel()
   - _leaveChannel()
   - _deleteChannel()

6. UI METHODS ................................................................. Line 268
   - _switchChannel()
   - _showSnackBar()
   - _showChannelOptionsDialog()
   - _showCreateChannelDialog()
   - _showJoinChannelDialog()
   - _showManageChannelsDialog()
   - _showCustomDialog()

===============================================================================
*/

class ACchatHome extends StatefulWidget {
  const ACchatHome({super.key});

  @override
  State<ACchatHome> createState() => _ACchatHomeState();
}

class _ACchatHomeState extends State<ACchatHome> {

  // ============================================================================
  //                                    VARIABLES
  // ============================================================================
  // VARIABLES USED THROUGHOUT THE CLASS.

  final ApiService _apiService = ApiService();
  late final RecorderService _recorderService;
  late final StreamController<Uint8List> _audioStreamController;
  StreamSubscription<Uint8List>? _audioStreamSubscription;

  bool isConnected = false;
  bool isTalking = false;
  int channelIndex = 0;
  late ValueNotifier<List<dynamic>> channelsNotifier;

  bool _microphonePermissionDenied = false;

  // SERVER STATUS
  bool _serverOnline = true;

  // COMMON TEXT STYLE
  final TextStyle _textStyle = const TextStyle(
    color: Colors.white,
    fontSize: 16,
    fontFamily: 'RetroFont',
  );

  // ============================================================================
  //                                   INITIALIZATION
  // ============================================================================
  // INITIALIZING THE STATE AND SETUP.

  @override
  void initState() {
    super.initState();
    _audioStreamController = StreamController<Uint8List>();
    _recorderService = RecorderService(_audioStreamController.sink);
    _openRecorder();
    _setupAudioStreamListener();
    channelsNotifier = ValueNotifier<List<dynamic>>([]);
    _initializeUser();
    _setupEventListener();
    _apiService.startHeartbeat();

    // PRELOAD IMAGES
    WidgetsBinding.instance.addPostFrameCallback((_) {
      precacheImage(const AssetImage('assets/images/talk_active.png'), context);
      precacheImage(const AssetImage('assets/images/talk_inactive.png'), context);
    });
  }

  Future<void> _initializeUser() async {
    try {
      await _apiService.initializeUserId();
    } catch (e) {
      Logger.log('Error initializing user ID: $e');
    }

    await _fetchChannels();
    await _loadLastSelectedChannel();
  }

  Future<void> _loadLastSelectedChannel() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? lastChannel = prefs.getString('lastChannel');
    if (lastChannel != null) {
      int index = channelsNotifier.value.indexWhere((channel) => channel['name'] == lastChannel);
      if (index != -1) {
        setState(() {
          channelIndex = index;
        });
      }
    }
  }

  Future<void> _openRecorder() async {
    var status = await Permission.microphone.request();
    if (status.isGranted) {
      await _recorderService.openRecorder();
    } else {
      // PERMISSION DENIED
      setState(() {
        _microphonePermissionDenied = true;
      });
      return;
    }
  }

  // ============================================================================
  //                                  EVENT LISTENERS
  // ============================================================================
  // SETTING UP EVENT LISTENERS.

  void _setupEventListener() {
    _apiService.events.listen((event) async {
      if (event['type'] == 'server_online') {
        _showSnackBar('Server is back online.');
        setState(() {
          _serverOnline = true;
        });
        await _fetchChannels();
        if (!mounted) return;

        if (channelsNotifier.value.isNotEmpty) {
          if (channelIndex == -1) {
            setState(() {
              channelIndex = 0;
            });
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.setString('lastChannel', channelsNotifier.value[channelIndex]['name']);
          }
        }

        // RECONNECT IF PREVIOUSLY CONNECTED
        if (isConnected) {
          String channelName = channelsNotifier.value.isNotEmpty && channelIndex >= 0
              ? channelsNotifier.value[channelIndex]['name']
              : null;
          _connect(channelName);
        }
      }

      // HANDLE CHANNEL DELETED EVENT
      if (event['type'] == 'channel_deleted') {
        String deletedChannel = event['channelName'];
        String? currentChannelName = channelsNotifier.value.isNotEmpty &&
                channelIndex >= 0 &&
                channelIndex < channelsNotifier.value.length
            ? channelsNotifier.value[channelIndex]['name']
            : null;

        await _fetchChannels();
        if (!mounted) return;

        if (deletedChannel == currentChannelName) {
          // CURRENT CHANNEL DELETED
          int newIndex = channelsNotifier.value
              .indexWhere((channel) => channel['name'] == 'Channel 1');
          if (newIndex != -1) {
            setState(() {
              channelIndex = newIndex;
            });
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.setString('lastChannel', 'Channel 1');
            if (isConnected) {
              _apiService.switchChannel('Channel 1');
            } else {
              _connect('Channel 1');
            }
            _showSnackBar(
                'Channel "$deletedChannel" has been deleted. Switched to "Channel 1".');
          } else if (channelsNotifier.value.isNotEmpty) {
            // SWITCH TO FIRST AVAILABLE CHANNEL
            setState(() {
              channelIndex = 0;
            });
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.setString('lastChannel', channelsNotifier.value[channelIndex]['name']);
            if (isConnected) {
              _apiService.switchChannel(channelsNotifier.value[channelIndex]['name']);
            } else {
              _connect(channelsNotifier.value[channelIndex]['name']);
            }
            _showSnackBar(
                'Channel "$deletedChannel" has been deleted. Switched to "${channelsNotifier.value[channelIndex]['name']}".');
          } else {
            // NO CHANNELS AVAILABLE
            setState(() {
              channelIndex = -1;
              isConnected = false;
            });
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.remove('lastChannel');
            if (isConnected) {
              _disconnect();
            }
            _showSnackBar(
                'Channel "$deletedChannel" has been deleted. No channels available.');
          }
        } else {
          // DELETED CHANNEL IS NOT CURRENT CHANNEL
          int newIndex = channelsNotifier.value
              .indexWhere((channel) => channel['name'] == currentChannelName);
          if (newIndex != -1) {
            setState(() {
              channelIndex = newIndex;
            });
          } else if (channelsNotifier.value.isNotEmpty) {
            setState(() {
              channelIndex = 0;
            });
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.setString('lastChannel', channelsNotifier.value[channelIndex]['name']);
            if (isConnected) {
              _apiService.switchChannel(channelsNotifier.value[channelIndex]['name']);
            } else {
              _connect(channelsNotifier.value[channelIndex]['name']);
            }
          } else {
            // NO CHANNELS LEFT
            setState(() {
              channelIndex = -1;
              isConnected = false;
            });
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.remove('lastChannel');
            if (isConnected) {
              _disconnect();
            }
          }
          _showSnackBar('Channel "$deletedChannel" has been deleted.');
        }
      } else if (event['type'] == 'connection_error') {
        _showSnackBar('Lost connection to the server.');
        setState(() {
          isConnected = false;
        });
      } else if (event['type'] == 'connection_closed') {
        // CONNECTION CLOSED
        Logger.log('Connection closed.');
        if (!_apiService.isSwitchingChannel) {
          setState(() {
            isConnected = false;
          });
        }
      } else if (event['type'] == 'notice') {
        _showSnackBar('Host: ${event['message'] ?? ''}');
      } else if (event['type'] == 'kicked') {
        _showSnackBar('You were removed from the channel.');
        setState(() {
          isConnected = false;
        });
      } else if (event['type'] == 'recording_started') {
        _showSnackBar('Recording started on this channel.');
      } else if (event['type'] == 'recording_stopped') {
        _showSnackBar('Recording saved.');
      } else if (event['type'] == 'server_offline') {
        _showSnackBar('Server is offline.');
        setState(() {
          _serverOnline = false;
          isConnected = false;
        });
      } else if (event['type'] == 'server_online') {
        _showSnackBar('Server is back online.');
        setState(() {
          _serverOnline = true;
        });
        await _fetchChannels();

        // RECONNECT IF PREVIOUSLY CONNECTED
        if (isConnected) {
          _connect();
        }
      }
    });
  }

  void _setupAudioStreamListener() {
    _audioStreamSubscription = _audioStreamController.stream.listen((audioChunk) {
      if (isConnected) {
        _apiService.sendAudioStream(audioChunk);
      }
    });
  }

  // ============================================================================
  //                                 RECORDER METHODS
  // ============================================================================
  // STARTING AND STOPPING AUDIO STREAMING.

  void _startStreaming() async {
    if (!isConnected || _microphonePermissionDenied) {
      _showSnackBar('Please turn on the walkie talkie first.');
      return;
    }

    await _recorderService.startRecording();

    setState(() {
      isTalking = true;
    });
  }

  void _stopStreaming() async {
    await _recorderService.stopRecording();

    setState(() {
      isTalking = false;
    });
  }

  // ============================================================================
  //                                    API CALLS
  // ============================================================================
  // INTERACT WITH THE API SERVICE.

  Future<void> _fetchChannels() async {
    try {
      final fetchedChannels = await _apiService.fetchChannels();
      if (!mounted) return;

      setState(() {
        channelsNotifier.value = fetchedChannels;
        if (channelsNotifier.value.isNotEmpty) {
          if (channelIndex == -1) {
            // SET CHANNELINDEX TO 0
            channelIndex = 0;
          } else if (channelIndex >= channelsNotifier.value.length) {
            // ADJUST CHANNELINDEX
            channelIndex = channelsNotifier.value.length - 1;
          }
        } else {
          // NO CHANNELS AVAILABLE
          channelIndex = -1;
        }
      });
    } catch (e) {
      Logger.log('Error fetching channels: $e');
      if (!mounted) return;
      setState(() {
        channelsNotifier.value = [];
        channelIndex = -1;
      });
    }

    // REMEMBER LAST CONNECTED CHANNEL
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? lastChannel = prefs.getString('lastChannel');
    if (lastChannel != null) {
      int index = channelsNotifier.value.indexWhere((channel) => channel['name'] == lastChannel);
      if (index != -1) {
        setState(() {
          channelIndex = index;
        });
      } else if (channelsNotifier.value.isNotEmpty) {
        setState(() {
          channelIndex = 0;
        });
        prefs.setString('lastChannel', channelsNotifier.value[0]['name']);
      } else {
        setState(() {
          channelIndex = -1;
        });
        prefs.remove('lastChannel');
      }
    }
  }

  void _connect([String? channelName]) {
    if (isConnected || _microphonePermissionDenied) return;
    if (!_serverOnline) {
      _showSnackBar('Attempting to connect, but the server appears to be offline.');
    }
    if (channelIndex == -1 || channelsNotifier.value.isEmpty) {
      _showSnackBar('No channels available to connect.');
      return;
    }
    try {
      String channelToConnect = channelName ?? channelsNotifier.value[channelIndex]['name'];
      _apiService.connectToWebSocket(channelToConnect);
      setState(() {
        isConnected = true;
      });
    } catch (e) {
      Logger.log('Connection error: $e');
      _showSnackBar('Failed to connect to the server.');
      setState(() {
        isConnected = false;
      });
    }
  }

  void _disconnect() {
    if (!isConnected) return;
    _apiService.closeWebSocket();
    setState(() {
      isConnected = false;
    });
  }

  Future<void> _createChannel(String channelName) async {
    if (!_serverOnline) {
      _showSnackBar('Cannot create channel: Server is offline.');
      return;
    }
    bool success = await _apiService.createChannel(channelName);
    if (success) {
      await _fetchChannels();
      if (!mounted) return;

      int newIndex =
          channelsNotifier.value.indexWhere((channel) => channel['name'] == channelName);
      if (newIndex != -1) {
        setState(() {
          channelIndex = newIndex;
        });
        SharedPreferences prefs = await SharedPreferences.getInstance();
        prefs.setString('lastChannel', channelName);
        if (isConnected) {
          _apiService.switchChannel(channelName);
        }
        if (mounted) _showSnackBar('Channel "$channelName" created.');
      }
      if (mounted) Navigator.of(context).pop();
    } else {
      _showSnackBar('Failed to create channel. It may already exist or server error.');
    }
  }

  Future<void> _joinChannel(String channelName) async {
    if (!_serverOnline) {
      _showSnackBar('Cannot join channel: Server is offline.');
      return;
    }
    bool success = await _apiService.joinChannel(channelName);
    if (success) {
      await _fetchChannels();
      if (!mounted) return;

      int newIndex =
          channelsNotifier.value.indexWhere((channel) => channel['name'] == channelName);
      if (newIndex == -1) {
        if (mounted) _showSnackBar('Channel "$channelName" does not exist.');
        return;
      }

      if (channelsNotifier.value[channelIndex]['name'] == channelName) {
        if (mounted) _showSnackBar('You are already in channel "$channelName".');
        return;
      }

      setState(() {
        channelIndex = newIndex;
      });

      SharedPreferences prefs = await SharedPreferences.getInstance();
      prefs.setString('lastChannel', channelName);

      if (isConnected) {
        _apiService.switchChannel(channelName);
      }

      if (mounted) {
        _showSnackBar('Joined channel "$channelName".');
        Navigator.of(context).pop();
      }
    } else {
      _showSnackBar('Failed to join channel. It may not exist or server error.');
    }
  }

  Future<void> _leaveChannel(String channelName) async {
    if (!_serverOnline) {
      _showSnackBar('Cannot leave channel: Server is offline.');
      return;
    }

    String? currentChannelName = channelsNotifier.value.isNotEmpty &&
            channelIndex >= 0 &&
            channelIndex < channelsNotifier.value.length
        ? channelsNotifier.value[channelIndex]['name']
        : null;

    bool success = await _apiService.leaveChannel(channelName);
    if (success) {
      await _fetchChannels();
      if (!mounted) return;

      if (channelsNotifier.value.isNotEmpty) {
        if (currentChannelName == channelName) {
          // LEFT CURRENT CHANNEL
          int newIndex = channelsNotifier.value
              .indexWhere((channel) => channel['name'] == 'Channel 1');
          if (newIndex != -1) {
            setState(() {
              channelIndex = newIndex;
            });
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.setString('lastChannel', 'Channel 1');
            if (isConnected) {
              _apiService.switchChannel('Channel 1');
            } else {
              _connect('Channel 1');
            }
          } else {
            // SWITCH TO FIRST AVAILABLE CHANNEL
            setState(() {
              channelIndex = 0;
            });
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.setString('lastChannel', channelsNotifier.value[channelIndex]['name']);
            if (isConnected) {
              _apiService.switchChannel(channelsNotifier.value[channelIndex]['name']);
            } else {
              _connect(channelsNotifier.value[channelIndex]['name']);
            }
          }
        } else {
          // LEFT A DIFFERENT CHANNEL
          int newIndex = channelsNotifier.value
              .indexWhere((channel) => channel['name'] == currentChannelName);
          if (newIndex != -1) {
            setState(() {
              channelIndex = newIndex;
            });
          } else {
            int channel1Index = channelsNotifier.value
                .indexWhere((channel) => channel['name'] == 'Channel 1');
            if (channel1Index != -1) {
              setState(() {
                channelIndex = channel1Index;
              });
              SharedPreferences prefs = await SharedPreferences.getInstance();
              prefs.setString('lastChannel', 'Channel 1');
              if (isConnected) {
                _apiService.switchChannel('Channel 1');
              } else {
                _connect('Channel 1');
              }
            } else {
              setState(() {
                channelIndex = 0;
              });
              SharedPreferences prefs = await SharedPreferences.getInstance();
              prefs.setString('lastChannel', channelsNotifier.value[channelIndex]['name']);
              if (isConnected) {
                _apiService.switchChannel(channelsNotifier.value[channelIndex]['name']);
              } else {
                _connect(channelsNotifier.value[channelIndex]['name']);
              }
            }
          }
          _showSnackBar('Left channel "${channelName.toUpperCase()}".');
        }
      } else {
        SharedPreferences prefs = await SharedPreferences.getInstance();
        prefs.remove('lastChannel');
        _showSnackBar('No channels available.');
        _disconnect();
      }
    } else {
      _showSnackBar('Failed to leave channel.');
    }
  }

  Future<void> _deleteChannel(String channelName) async {
    if (!_serverOnline) {
      _showSnackBar('Cannot delete channel: Server is offline.');
      return;
    }
    bool success = await _apiService.deleteChannel(channelName);
    if (success) {
      await _fetchChannels();
      if (channelsNotifier.value.isNotEmpty) {
        if (channelsNotifier.value[channelIndex]['name'] == channelName) {
          // DELETED CURRENT CHANNEL
          int newIndex = channelsNotifier.value
              .indexWhere((channel) => channel['name'] == 'Channel 1');
          if (newIndex != -1) {
            setState(() {
              channelIndex = newIndex;
            });
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.setString('lastChannel', 'Channel 1');
            if (isConnected) {
              _apiService.switchChannel('Channel 1');
            } else {
              _connect('Channel 1');
            }
          } else {
            setState(() {
              channelIndex = 0;
            });
            SharedPreferences prefs = await SharedPreferences.getInstance();
            prefs.setString('lastChannel', channelsNotifier.value[channelIndex]['name']);
            if (isConnected) {
              _apiService.switchChannel(channelsNotifier.value[channelIndex]['name']);
            } else {
              _connect(channelsNotifier.value[channelIndex]['name']);
            }
          }
          _showSnackBar(
              'Channel "$channelName" deleted. Switched to "${channelsNotifier.value[channelIndex]['name']}".');
        } else {
          _showSnackBar('Channel "$channelName" deleted.');
        }
      } else {
        SharedPreferences prefs = await SharedPreferences.getInstance();
        prefs.remove('lastChannel');
        _showSnackBar('Channel "$channelName" deleted. No channels available.');
        _disconnect();
      }
    } else {
      _showSnackBar('Failed to delete channel.');
    }
  }

  // ============================================================================
  //                                    UI METHODS
  // ============================================================================
  // UI INTERACTIONS AND DIALOGS.

  void _switchChannel(int delta) {
    bool wasConnected = isConnected;
    if (isConnected) {
      _apiService.switchChannel(
          channelsNotifier.value[(channelIndex + delta) % channelsNotifier.value.length]['name']);
    }
    setState(() {
      int newIndex = (channelIndex + delta) % channelsNotifier.value.length;
      if (newIndex < 0) {
        newIndex += channelsNotifier.value.length;
      }
      channelIndex = newIndex;
    });
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('lastChannel', channelsNotifier.value[channelIndex]['name']);
    });
    if (wasConnected) {
      // NO NEED TO RECONNECT
    }
  }

  void _showSnackBar(String message) {
    // REMOVE EXISTING BANNER
    ScaffoldMessenger.of(context).removeCurrentMaterialBanner();

    // CREATE NEW BANNER
    final materialBanner = MaterialBanner(
      content: Text(
        message,
        style: const TextStyle(color: Colors.white),
      ),
      backgroundColor: Colors.black87,
      actions: [
        TextButton(
          onPressed: () {
            if (!mounted) return;
            ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
          },
          child: const Text(
            'DISMISS',
            style: TextStyle(color: Colors.white),
          ),
        ),
      ],
    );

    // SHOW BANNER
    ScaffoldMessenger.of(context)
      ..clearMaterialBanners()
      ..showMaterialBanner(materialBanner);

    // AUTO DISMISS AFTER 3 SECONDS
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
    });
  }

  void _showChannelOptionsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return _CustomDialog(
          title: 'Channel Options',
          icon: Icons.settings,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DialogOption(
                icon: Icons.add,
                text: 'Create Channel',
                onTap: () {
                  Navigator.of(context).pop();
                  _showCreateChannelDialog();
                },
              ),
              _DialogOption(
                icon: Icons.login,
                text: 'Join Channel',
                onTap: () {
                  Navigator.of(context).pop();
                  _showJoinChannelDialog();
                },
              ),
              _DialogOption(
                icon: Icons.list,
                text: 'Manage Channels',
                onTap: () {
                  Navigator.of(context).pop();
                  _showManageChannelsDialog();
                },
              ),
              _DialogOption(
                icon: Icons.mic,
                text: 'Recordings',
                onTap: () {
                  Navigator.of(context).pop();
                  _showRecordingsDialog();
                },
              ),
              if (_isCurrentChannelHost())
                _DialogOption(
                  icon: Icons.admin_panel_settings,
                  text: 'Admin Panel',
                  onTap: () {
                    Navigator.of(context).pop();
                    _showAdminPanelDialog();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _showCreateChannelDialog() {
    String channelName = '';
    _showCustomDialog(
      title: 'Create Channel',
      icon: Icons.add,
      content: SingleChildScrollView(
        child: Column(
          children: [
            TextField(
              onChanged: (value) {
                channelName = value.trim();
              },
              style: _textStyle,
              decoration: InputDecoration(
                hintText: 'Enter channel name',
                hintStyle: _textStyle.copyWith(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.5))),
                focusedBorder:
                    const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _DialogButton(
                  icon: Icons.arrow_back,
                  onTap: () {
                    Navigator.of(context).pop();
                    _showChannelOptionsDialog();
                  },
                ),
                const SizedBox(width: 10),
                _DialogButton(
                  icon: Icons.check,
                  onTap: () async {
                    if (channelName.isNotEmpty) {
                      await _createChannel(channelName);
                    } else {
                      _showSnackBar('Channel name cannot be empty.');
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
      iconVerticalOffset: 1.0,
    );
  }

  void _showJoinChannelDialog() {
    String channelName = '';
    _showCustomDialog(
      title: 'Join Channel',
      icon: Icons.login,
      content: SingleChildScrollView(
        child: Column(
          children: [
            TextField(
              onChanged: (value) {
                channelName = value.trim();
              },
              style: _textStyle,
              decoration: InputDecoration(
                hintText: 'Enter channel name',
                hintStyle: _textStyle.copyWith(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.5))),
                focusedBorder:
                    const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _DialogButton(
                  icon: Icons.arrow_back,
                  onTap: () {
                    Navigator.of(context).pop();
                    _showChannelOptionsDialog();
                  },
                ),
                const SizedBox(width: 10),
                _DialogButton(
                  icon: Icons.check,
                  onTap: () async {
                    if (channelName.isNotEmpty) {
                      await _joinChannel(channelName);
                    } else {
                      _showSnackBar('Channel name cannot be empty.');
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
      iconVerticalOffset: 1.0,
    );
  }

  void _showManageChannelsDialog() {
    _showCustomDialog(
      title: 'Manage Channels',
      icon: Icons.list,
      content: ValueListenableBuilder<List<dynamic>>(
        valueListenable: channelsNotifier,
        builder: (context, channelsList, _) {
          List<dynamic> userChannels = channelsList.where((channel) {
            return channel['creatorId'] == _apiService.userId ||
                (channel['members'] != null && channel['members'].contains(_apiService.userId));
          }).toList();

          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (userChannels.isNotEmpty)
                  Flexible(
                    child: ListView.builder(
                      itemCount: userChannels.length,
                      itemBuilder: (context, index) {
                        var channel = userChannels[index];
                        String channelName = channel['name'];

                        return _ChannelCard(
                          channelName: channelName,
                          isOwner: channel['creatorId'] == _apiService.userId,
                          onDelete: () async {
                            if (channel['creatorId'] == _apiService.userId) {
                              await _deleteChannel(channelName);
                            } else {
                              await _leaveChannel(channelName);
                            }
                          },
                          onTap: () {
                            int newIndex = channelsNotifier.value
                                .indexWhere((ch) => ch['name'] == channelName);
                            if (newIndex != -1) {
                              _switchChannel(newIndex - channelIndex);
                              Navigator.of(context).pop();
                              _showSnackBar('Switched to "$channelName".');
                            }
                          },
                        );
                      },
                    ),
                  )
                else
                  const SizedBox(height: 10),
                if (userChannels.isEmpty)
                  Text(
                    'No channels available.',
                    style: _textStyle.copyWith(color: Colors.white70),
                  ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _DialogButton(
                      icon: Icons.arrow_back,
                      onTap: () {
                        Navigator.of(context).pop();
                        _showChannelOptionsDialog();
                      },
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
      iconVerticalOffset: 1.0,
    );
  }

  String get _currentChannelName {
    if (channelsNotifier.value.isEmpty ||
        channelIndex < 0 ||
        channelIndex >= channelsNotifier.value.length) {
      return '';
    }
    return channelsNotifier.value[channelIndex]['name'] as String;
  }

  bool _isCurrentChannelHost() {
    if (channelsNotifier.value.isEmpty ||
        channelIndex < 0 ||
        channelIndex >= channelsNotifier.value.length) {
      return false;
    }
    return channelsNotifier.value[channelIndex]['creatorId'] == _apiService.userId;
  }

  // ===========================================================================
  // RECORDINGS
  // ===========================================================================
  // View saved voice notes + transcripts for the current channel. The host can
  // start/stop recording and delete; all members can play, view transcripts,
  // and trigger transcription. Recordings are saved server-side and stay
  // available to both parties at any time.

  void _showRecordingsDialog() {
    final channelName = _currentChannelName;
    if (channelName.isEmpty) {
      _showSnackBar('No channel selected.');
      return;
    }

    _showCustomDialog(
      title: 'Recordings',
      icon: Icons.mic,
      content: FutureBuilder<Map<String, dynamic>?>(
        future: _apiService.fetchRecordings(channelName),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
          final data = snapshot.data;
          final List recordings =
              data != null ? (data['recordings'] ?? []) as List : [];
          final bool recording = data != null ? data['recording'] == true : false;
          final bool isHost = _isCurrentChannelHost();

          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.55,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isHost)
                  _RecordingControlRow(
                    isRecording: recording,
                    onStart: () async {
                      final nav = Navigator.of(context);
                      final ok = await _apiService.startRecording(channelName);
                      if (!mounted) return;
                      nav.pop();
                      _showSnackBar(
                          ok ? 'Recording started.' : 'Failed to start recording.');
                      if (ok) _showRecordingsDialog();
                    },
                    onStop: () async {
                      final nav = Navigator.of(context);
                      final id = await _apiService.stopRecording(channelName);
                      if (!mounted) return;
                      nav.pop();
                      _showSnackBar(
                          id != null ? 'Recording saved.' : 'Failed to stop recording.');
                      _showRecordingsDialog();
                    },
                  ),
                if (recordings.isEmpty && !recording)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'No recordings yet.',
                      style: _textStyle.copyWith(color: Colors.white70),
                    ),
                  ),
                if (recordings.isNotEmpty)
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: recordings.length,
                      itemBuilder: (context, index) {
                        final rec = recordings[index];
                        return _RecordingCard(
                          recording: rec,
                          onPlay: () => _apiService.playRecording(
                              _apiService.recordingAudioUrl(rec['id'])),
                          onStop: () => _apiService.stopPlayback(),
                          onTranscript: () =>
                              _showTranscriptDialog(rec['id'], rec['hasTranscript'] == true),
                          onDelete: () async {
                            final nav = Navigator.of(context);
                            final ok = await _apiService.deleteRecording(rec['id']);
                            if (!mounted) return;
                            nav.pop();
                            _showSnackBar(
                                ok ? 'Recording deleted.' : 'Failed to delete.');
                            _showRecordingsDialog();
                          },
                          canDelete: isHost,
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _DialogButton(
                      icon: Icons.arrow_back,
                      onTap: () async {
                        final nav = Navigator.of(context);
                        await _apiService.stopPlayback();
                        if (!mounted) return;
                        nav.pop();
                        _showChannelOptionsDialog();
                      },
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
      iconVerticalOffset: 1.0,
    );
  }

  void _showTranscriptDialog(String recordingId, bool hasTranscript) {
    _showCustomDialog(
      title: 'Transcript',
      icon: Icons.description,
      content: FutureBuilder<String?>(
        future: _apiService.fetchTranscript(recordingId),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
          final text = snapshot.data ?? '';
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (text.isNotEmpty)
                  Flexible(
                    child: SingleChildScrollView(
                      child: SelectableText(text, style: _textStyle),
                    ),
                  ),
                if (text.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'No transcript yet. Tap the wand to transcribe.',
                      style: _textStyle.copyWith(color: Colors.white70),
                    ),
                  ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _DialogButton(
                      icon: Icons.auto_fix_high,
                      onTap: () async {
                        Navigator.of(context).pop();
                        _showSnackBar('Transcribing... this may take a moment.');
                        final t = await _apiService.transcribeRecording(recordingId);
                        if (!mounted) return;
                        if (t != null) {
                          _showTranscriptDialog(recordingId, true);
                        } else {
                          _showSnackBar(
                              'Transcription failed. Is OPENAI_API_KEY set on the server?');
                        }
                      },
                    ),
                    const SizedBox(width: 10),
                    _DialogButton(
                      icon: Icons.arrow_back,
                      onTap: () {
                        Navigator.of(context).pop();
                        _showRecordingsDialog();
                      },
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
      iconVerticalOffset: 1.0,
    );
  }

  // ===========================================================================
  // ADMIN PANEL (host only)
  // ===========================================================================
  // The channel creator can view members + connected clients, kick a member,
  // and broadcast a notice to the whole channel.

  void _showAdminPanelDialog() async {
    final channelName = _currentChannelName;
    if (channelName.isEmpty) return;
    if (!_isCurrentChannelHost()) {
      _showSnackBar('Only the host can open the admin panel.');
      return;
    }

    final membersData = await _apiService.fetchMembers(channelName);
    final connected = await _apiService.fetchConnectedClients(channelName);
    if (!mounted) return;

    final List members =
        membersData != null ? (membersData['members'] ?? []) as List : [];
    final String? creatorId =
        membersData != null ? membersData['creatorId'] as String? : null;
    final Set<String> connectedIds =
        connected.map((c) => c['userId'] as String).toSet();

    String notice = '';

    _showCustomDialog(
      title: 'Admin Panel',
      icon: Icons.admin_panel_settings,
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Channel: $channelName', style: _textStyle),
            const SizedBox(height: 10),
            Text('Members (${members.length})',
                style: _textStyle.copyWith(color: Colors.white70, fontSize: 14)),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: members.length,
                itemBuilder: (context, index) {
                  final m = members[index] as String;
                  return _MemberTile(
                    userId: m,
                    isCreator: m == creatorId,
                    online: connectedIds.contains(m),
                    isSelf: m == _apiService.userId,
                    onKick: (m == creatorId)
                        ? null
                        : () async {
                            final nav = Navigator.of(context);
                            final ok = await _apiService.kickMember(channelName, m);
                            if (!mounted) return;
                            _showSnackBar(
                                ok ? 'Member removed.' : 'Failed to remove member.');
                            if (ok) {
                              nav.pop();
                              _showAdminPanelDialog();
                            }
                          },
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Text('Broadcast notice',
                style: _textStyle.copyWith(color: Colors.white70, fontSize: 14)),
            TextField(
              onChanged: (v) => notice = v,
              style: _textStyle,
              decoration: InputDecoration(
                hintText: 'Message to the channel',
                hintStyle: _textStyle.copyWith(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.5))),
                focusedBorder:
                    const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _DialogButton(
                  icon: Icons.send,
                  onTap: () async {
                    if (notice.trim().isEmpty) {
                      _showSnackBar('Notice cannot be empty.');
                      return;
                    }
                    final ok =
                        await _apiService.broadcastNotice(channelName, notice.trim());
                    if (!mounted) return;
                    _showSnackBar(ok ? 'Notice sent.' : 'Failed to send notice.');
                  },
                ),
                const SizedBox(width: 10),
                _DialogButton(
                  icon: Icons.arrow_back,
                  onTap: () {
                    Navigator.of(context).pop();
                    _showChannelOptionsDialog();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
      iconVerticalOffset: 1.0,
    );
  }

  void _showCustomDialog({
    required String title,
    required IconData icon,
    required Widget content,
    List<Widget>? actions,
    double iconVerticalOffset = 0.0,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return _CustomDialog(
          title: title,
          icon: icon,
          content: content,
          actions: actions,
          iconVerticalOffset: iconVerticalOffset,
        );
      },
    );
  }

  // ============================================================================
  //                                   DISPOSE METHOD
  // ============================================================================
  // CLEANUP RESOURCES WHEN THE WIDGET IS DISPOSED.

  @override
  void dispose() {
    if (isTalking) {
      _stopStreaming();
    }
    if (isConnected) {
      _disconnect();
    }
    _recorderService.closeRecorder();
    _audioStreamSubscription?.cancel();
    _audioStreamController.close();
    _apiService.dispose();
    channelsNotifier.dispose();
    super.dispose();
  }

  // ============================================================================
  //                                    BUILD METHOD
  // ============================================================================
  // BUILD THE WIDGET TREE.

  @override
  Widget build(BuildContext context) {
    // SHOW SNACKBAR IF MICROPHONE PERMISSION IS DENIED
    if (_microphonePermissionDenied) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showSnackBar('Microphone permission is required.');
      });
    }

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Center(
        child: ValueListenableBuilder<List<dynamic>>(
          valueListenable: channelsNotifier,
          builder: (context, channelsList, _) {
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // CONNECTIVITY CARD
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.85,
                  child: ConnectivityCard(
                    isConnected: isConnected,
                    channelIndex: channelIndex,
                    channels: channelsList
                        .map<String>((channel) => channel['name'] as String)
                        .toList(),
                    onConnect: _connect,
                    onDisconnect: _disconnect,
                    onSwitchChannel: _switchChannel,
                    onChannelOptions: _showChannelOptionsDialog,
                  ),
                ),
                const SizedBox(height: 40),
                // PUSH-TO-TALK BUTTON
                GestureDetector(
                  onTapDown: (_) {
                    if (isConnected) {
                      _startStreaming();
                    } else {
                      _showSnackBar('Please turn on the walkie talkie first.');
                    }
                  },
                  onTapUp: (_) {
                    if (isConnected) {
                      _stopStreaming();
                    }
                  },
                  child: Image.asset(
                    isTalking
                        ? 'assets/images/talk_active.png'
                        : 'assets/images/talk_inactive.png',
                    width: 300,
                    height: 300,
                    gaplessPlayback: true,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// Custom Dialog Widget
class _CustomDialog extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget content;
  final List<Widget>? actions;
  final double iconVerticalOffset;

  const _CustomDialog({
    required this.title,
    required this.icon,
    required this.content,
    this.actions,
    this.iconVerticalOffset = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    const TextStyle textStyle = TextStyle(
      color: Colors.white,
      fontSize: 16,
      fontFamily: 'RetroFont',
    );

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 0, 0, 0).withOpacity(0.9),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white54),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Transform.translate(
                      offset: Offset(0, iconVerticalOffset),
                      child: Icon(icon, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        style: textStyle,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                content,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Dialog Option Widget
class _DialogOption extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onTap;
  final double iconVerticalOffset;

  const _DialogOption({
    required this.icon,
    required this.text,
    required this.onTap,
    // ignore: unused_element
    this.iconVerticalOffset = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    const TextStyle textStyle = TextStyle(
      color: Colors.white,
      fontSize: 16,
      fontFamily: 'RetroFont',
    );

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white24),
        ),
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 10),
        margin: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Transform.translate(
              offset: Offset(0, iconVerticalOffset),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: textStyle,
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white54),
          ],
        ),
      ),
    );
  }
}

// Dialog Button Widget
class _DialogButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  const _DialogButton({
    required this.icon,
    required this.onTap,
    // ignore: unused_element
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: const BoxDecoration(
            color: Color.fromARGB(202, 255, 255, 255), shape: BoxShape.circle),
        padding: const EdgeInsets.all(8.0),
        child: Icon(
          icon,
          color: Colors.black,
          size: 25.0,
        ),
      ),
    );
  }
}

// Channel Card Widget
class _ChannelCard extends StatelessWidget {
  final String channelName;
  final bool isOwner;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  const _ChannelCard({
    required this.channelName,
    required this.isOwner,
    required this.onDelete,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const TextStyle textStyle = TextStyle(
      color: Colors.white,
      fontSize: 16,
      fontFamily: 'RetroFont',
    );

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white24),
        ),
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 10),
        margin: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            const Icon(Icons.chat_bubble, color: Colors.white, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                channelName,
                style: textStyle,
              ),
            ),
            IconButton(
              icon: Icon(
                isOwner ? Icons.delete : Icons.exit_to_app,
                color: Colors.white,
              ),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

// Recording control row (start/stop) shown to the host.
class _RecordingControlRow extends StatelessWidget {
  final bool isRecording;
  final VoidCallback onStart;
  final VoidCallback onStop;

  const _RecordingControlRow({
    required this.isRecording,
    required this.onStart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(
            onPressed: isRecording ? null : onStart,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Start Recording'),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: isRecording ? onStop : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
            ),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
  }
}

// One saved recording: play/stop, view transcript, delete (host).
class _RecordingCard extends StatelessWidget {
  final dynamic recording;
  final VoidCallback onPlay;
  final VoidCallback onStop;
  final VoidCallback onTranscript;
  final VoidCallback onDelete;
  final bool canDelete;

  const _RecordingCard({
    required this.recording,
    required this.onPlay,
    required this.onStop,
    required this.onTranscript,
    required this.onDelete,
    required this.canDelete,
  });

  @override
  Widget build(BuildContext context) {
    final ts = DateTime.fromMillisecondsSinceEpoch(recording['createdAt'] ?? 0);
    final dur = Duration(milliseconds: recording['durationMs'] ?? 0);
    final durStr =
        '${dur.inMinutes}:${(dur.inSeconds % 60).toString().padLeft(2, '0')}';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white24),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.play_arrow, color: Colors.white),
            onPressed: onPlay,
          ),
          IconButton(
            icon: const Icon(Icons.stop, color: Colors.white),
            onPressed: onStop,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ts.toLocal().toString().substring(0, 19),
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14, fontFamily: 'RetroFont'),
                ),
                Text(
                  durStr,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12, fontFamily: 'RetroFont'),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.description, color: Colors.white),
            onPressed: onTranscript,
          ),
          if (canDelete)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.white),
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}

// One channel member row in the admin panel.
class _MemberTile extends StatelessWidget {
  final String userId;
  final bool isCreator;
  final bool online;
  final bool isSelf;
  final VoidCallback? onKick;

  const _MemberTile({
    required this.userId,
    required this.isCreator,
    required this.online,
    required this.isSelf,
    this.onKick,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white24),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            online ? Icons.circle : Icons.circle_outlined,
            color: online ? Colors.greenAccent : Colors.white54,
            size: 12,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              userId.substring(0, 8) +
                  (isSelf ? ' (you)' : '') +
                  (isCreator ? ' [host]' : ''),
              style: const TextStyle(
                  color: Colors.white, fontSize: 14, fontFamily: 'RetroFont'),
            ),
          ),
          if (onKick != null)
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
              onPressed: onKick,
            ),
        ],
      ),
    );
  }
}
