#pragma once

#include "../screen.h"
#include "../tui.h"

// Main menu item structure
struct MenuItem {
    const char* label;
    const char* description;
    int unreadCount;
    bool enabled;
};

// Main menu screen - entry point for the application
class MainMenuScreen : public Screen {
public:
    MainMenuScreen();
    ~MainMenuScreen() override = default;

    void onEnter() override;
    void render(Display& display) override;
    ScreenResult handleKey(KeyEvent key) override;
    const char* getTitle() override { return "MeshCore"; }

    // Update menu item badges
    void setMessageCount(int unread);
    void setChannelCount(int unread);
    void setContactCount(int count);
    void setNodeCount(int count);

private:
    static constexpr int MENU_ITEM_COUNT = 7;

    MenuItem _menuItems[MENU_ITEM_COUNT] = {
        {"Messages", "View conversations", 0, true},
        {"Channels", "Group messaging", 0, true},
        {"Contacts", "Known nodes", 0, true},
        {"Node Info", "Device status", 0, true},
        {"Settings", "Configuration", 0, true},
        {"Testing", "Diagnostics", 0, true},
        {"Snake", "Play a game", 0, true}
    };

    int _selectedIndex = 0;

    void selectNext();
    void selectPrevious();
    void activateSelected();
};
