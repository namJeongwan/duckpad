on run arguments
    set mountPath to item 1 of arguments
    set mountAlias to POSIX file mountPath as alias
    set backgroundFile to POSIX file (mountPath & "/.background/install.tiff") as alias
    tell application "Finder"
        set mountedFolder to folder mountAlias
        open mountedFolder
        tell container window of mountedFolder
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set bounds to {200, 160, 880, 576}
        end tell
        set viewOptions to icon view options of container window of mountedFolder
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 13
        set label position of viewOptions to bottom
        set shows icon preview of viewOptions to false
        set background picture of viewOptions to backgroundFile
        set position of item "Duckpad.app" of mountedFolder to {350, 160}
        set extension hidden of item "Duckpad.app" of mountedFolder to false
        set position of item "Applications" of mountedFolder to {520, 160}
        update mountedFolder without registering applications
        close container window of mountedFolder
    end tell
    -- Finder writes its view settings asynchronously.
    repeat 20 times
        delay 0.5
        try
            POSIX file (mountPath & "/.DS_Store") as alias
            return
        end try
    end repeat
    error "Finder did not persist the DMG layout"
end run
