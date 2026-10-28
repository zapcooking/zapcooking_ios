import Foundation

struct EmojiCategory {
    let name: String
    let icon: String
    let emojis: [String]
}

/// Static catalog of unicode emojis for the reaction picker / library.
/// Generated from Unicode's RGI `emoji-test.txt` — the canonical set shared
/// with Android (`EmojiData.kt`) and web. Regenerate with
/// `tools/gen-emoji-data.py`; never hand-edit the generated blocks.
enum EmojiData {
    /// Canonical quick-reaction defaults — identical on iOS, Android
    /// (`EmojiPicker.kt` `DEFAULT_UNICODE_EMOJIS`), and web (`QUICK_EMOJIS`
    /// in `reactions.ts`). 24 entries fill the picker's 4×6 grid: reactions
    /// first, then everything culinary together in sequence (chef, then
    /// food). Seasonal emoji stay in the catalog, not the defaults.
    /// Overridden by a user's configured list when set.
    // BEGIN GENERATED — tools/gen-emoji-data.py (do not edit)
    static let defaultQuickReactions: [String] = [
        "❤️", "🔥", "👍", "😂", "🙏", "🤙",
        "💯", "✨", "🎉", "🥂", "😋", "🤤",
        "🤌", "🧑‍🍳", "🍳", "🥩", "🍗", "🐟",
        "🥦", "🌶️", "🌮", "🍜", "🍝", "🍔",
    ]
    // END GENERATED

    /// Unicode catalog for the emoji library, generated from Unicode's RGI
    /// `emoji-test.txt` — the same set ships on Android (`EmojiData.kt`);
    /// the web full picker already renders it via `emoji-picker-element`.
    /// One glyph per concept: skin-tone and hair-tone variants are not
    /// listed (the OS keyboard covers those).
    // BEGIN GENERATED — tools/gen-emoji-data.py (emoji-test.txt 15.1; do not edit)
    static let categories: [EmojiCategory] = [
        EmojiCategory(
            name: "Smileys",
            icon: "😀",
            emojis: [
                "😀", "😃", "😄", "😁", "😆",
                "😅", "🤣", "😂", "🙂", "🙃",
                "🫠", "😉", "😊", "😇", "🥰",
                "😍", "🤩", "😘", "😗", "☺️",
                "😚", "😙", "🥲", "😋", "😛",
                "😜", "🤪", "😝", "🤑", "🤗",
                "🤭", "🫢", "🫣", "🤫", "🤔",
                "🫡", "🤐", "🤨", "😐", "😑",
                "😶", "🫥", "😶‍🌫️", "😏", "😒",
                "🙄", "😬", "😮‍💨", "🤥", "🫨",
                "🙂‍↔️", "🙂‍↕️", "😌", "😔", "😪",
                "🤤", "😴", "😷", "🤒", "🤕",
                "🤢", "🤮", "🤧", "🥵", "🥶",
                "🥴", "😵", "😵‍💫", "🤯", "🤠",
                "🥳", "🥸", "😎", "🤓", "🧐",
                "😕", "🫤", "😟", "🙁", "☹️",
                "😮", "😯", "😲", "😳", "🥺",
                "🥹", "😦", "😧", "😨", "😰",
                "😥", "😢", "😭", "😱", "😖",
                "😣", "😞", "😓", "😩", "😫",
                "🥱", "😤", "😡", "😠", "🤬",
                "😈", "👿", "💀", "☠️", "💩",
                "🤡", "👹", "👺", "👻", "👽",
                "👾", "🤖", "😺", "😸", "😹",
                "😻", "😼", "😽", "🙀", "😿",
                "😾", "🙈", "🙉", "🙊", "💌",
                "💘", "💝", "💖", "💗", "💓",
                "💞", "💕", "💟", "❣️", "💔",
                "❤️‍🔥", "❤️‍🩹", "❤️", "🩷", "🧡",
                "💛", "💚", "💙", "🩵", "💜",
                "🤎", "🖤", "🩶", "🤍", "💋",
                "💯", "💢", "💥", "💫", "💦",
                "💨", "🕳️", "💬", "👁️‍🗨️", "🗨️",
                "🗯️", "💭", "💤",
            ]
        ),
        EmojiCategory(
            name: "People",
            icon: "👋",
            emojis: [
                "👋", "🤚", "🖐️", "✋", "🖖",
                "🫱", "🫲", "🫳", "🫴", "🫷",
                "🫸", "👌", "🤌", "🤏", "✌️",
                "🤞", "🫰", "🤟", "🤘", "🤙",
                "👈", "👉", "👆", "🖕", "👇",
                "☝️", "🫵", "👍", "👎", "✊",
                "👊", "🤛", "🤜", "👏", "🙌",
                "🫶", "👐", "🤲", "🤝", "🙏",
                "✍️", "💅", "🤳", "💪", "🦾",
                "🦿", "🦵", "🦶", "👂", "🦻",
                "👃", "🧠", "🫀", "🫁", "🦷",
                "🦴", "👀", "👁️", "👅", "👄",
                "🫦", "👶", "🧒", "👦", "👧",
                "🧑", "👱", "👨", "🧔", "🧔‍♂️",
                "🧔‍♀️", "👩", "👱‍♀️", "👱‍♂️", "🧓",
                "👴", "👵", "🙍", "🙍‍♂️", "🙍‍♀️",
                "🙎", "🙎‍♂️", "🙎‍♀️", "🙅", "🙅‍♂️",
                "🙅‍♀️", "🙆", "🙆‍♂️", "🙆‍♀️", "💁",
                "💁‍♂️", "💁‍♀️", "🙋", "🙋‍♂️", "🙋‍♀️",
                "🧏", "🧏‍♂️", "🧏‍♀️", "🙇", "🙇‍♂️",
                "🙇‍♀️", "🤦", "🤦‍♂️", "🤦‍♀️", "🤷",
                "🤷‍♂️", "🤷‍♀️", "🧑‍⚕️", "👨‍⚕️", "👩‍⚕️",
                "🧑‍🎓", "👨‍🎓", "👩‍🎓", "🧑‍🏫", "👨‍🏫",
                "👩‍🏫", "🧑‍⚖️", "👨‍⚖️", "👩‍⚖️", "🧑‍🌾",
                "👨‍🌾", "👩‍🌾", "🧑‍🍳", "👨‍🍳", "👩‍🍳",
                "🧑‍🔧", "👨‍🔧", "👩‍🔧", "🧑‍🏭", "👨‍🏭",
                "👩‍🏭", "🧑‍💼", "👨‍💼", "👩‍💼", "🧑‍🔬",
                "👨‍🔬", "👩‍🔬", "🧑‍💻", "👨‍💻", "👩‍💻",
                "🧑‍🎤", "👨‍🎤", "👩‍🎤", "🧑‍🎨", "👨‍🎨",
                "👩‍🎨", "🧑‍✈️", "👨‍✈️", "👩‍✈️", "🧑‍🚀",
                "👨‍🚀", "👩‍🚀", "🧑‍🚒", "👨‍🚒", "👩‍🚒",
                "👮", "👮‍♂️", "👮‍♀️", "🕵️", "🕵️‍♂️",
                "🕵️‍♀️", "💂", "💂‍♂️", "💂‍♀️", "🥷",
                "👷", "👷‍♂️", "👷‍♀️", "🫅", "🤴",
                "👸", "👳", "👳‍♂️", "👳‍♀️", "👲",
                "🧕", "🤵", "🤵‍♂️", "🤵‍♀️", "👰",
                "👰‍♂️", "👰‍♀️", "🤰", "🫃", "🫄",
                "🤱", "👩‍🍼", "👨‍🍼", "🧑‍🍼", "👼",
                "🎅", "🤶", "🧑‍🎄", "🦸", "🦸‍♂️",
                "🦸‍♀️", "🦹", "🦹‍♂️", "🦹‍♀️", "🧙",
                "🧙‍♂️", "🧙‍♀️", "🧚", "🧚‍♂️", "🧚‍♀️",
                "🧛", "🧛‍♂️", "🧛‍♀️", "🧜", "🧜‍♂️",
                "🧜‍♀️", "🧝", "🧝‍♂️", "🧝‍♀️", "🧞",
                "🧞‍♂️", "🧞‍♀️", "🧟", "🧟‍♂️", "🧟‍♀️",
                "🧌", "💆", "💆‍♂️", "💆‍♀️", "💇",
                "💇‍♂️", "💇‍♀️", "🚶", "🚶‍♂️", "🚶‍♀️",
                "🚶‍➡️", "🚶‍♀️‍➡️", "🚶‍♂️‍➡️", "🧍", "🧍‍♂️",
                "🧍‍♀️", "🧎", "🧎‍♂️", "🧎‍♀️", "🧎‍➡️",
                "🧎‍♀️‍➡️", "🧎‍♂️‍➡️", "🧑‍🦯", "🧑‍🦯‍➡️", "👨‍🦯",
                "👨‍🦯‍➡️", "👩‍🦯", "👩‍🦯‍➡️", "🧑‍🦼", "🧑‍🦼‍➡️",
                "👨‍🦼", "👨‍🦼‍➡️", "👩‍🦼", "👩‍🦼‍➡️", "🧑‍🦽",
                "🧑‍🦽‍➡️", "👨‍🦽", "👨‍🦽‍➡️", "👩‍🦽", "👩‍🦽‍➡️",
                "🏃", "🏃‍♂️", "🏃‍♀️", "🏃‍➡️", "🏃‍♀️‍➡️",
                "🏃‍♂️‍➡️", "💃", "🕺", "🕴️", "👯",
                "👯‍♂️", "👯‍♀️", "🧖", "🧖‍♂️", "🧖‍♀️",
                "🧗", "🧗‍♂️", "🧗‍♀️", "🤺", "🏇",
                "⛷️", "🏂", "🏌️", "🏌️‍♂️", "🏌️‍♀️",
                "🏄", "🏄‍♂️", "🏄‍♀️", "🚣", "🚣‍♂️",
                "🚣‍♀️", "🏊", "🏊‍♂️", "🏊‍♀️", "⛹️",
                "⛹️‍♂️", "⛹️‍♀️", "🏋️", "🏋️‍♂️", "🏋️‍♀️",
                "🚴", "🚴‍♂️", "🚴‍♀️", "🚵", "🚵‍♂️",
                "🚵‍♀️", "🤸", "🤸‍♂️", "🤸‍♀️", "🤼",
                "🤼‍♂️", "🤼‍♀️", "🤽", "🤽‍♂️", "🤽‍♀️",
                "🤾", "🤾‍♂️", "🤾‍♀️", "🤹", "🤹‍♂️",
                "🤹‍♀️", "🧘", "🧘‍♂️", "🧘‍♀️", "🛀",
                "🛌", "🧑‍🤝‍🧑", "👭", "👫", "👬",
                "💏", "👩‍❤️‍💋‍👨", "👨‍❤️‍💋‍👨", "👩‍❤️‍💋‍👩", "💑",
                "👩‍❤️‍👨", "👨‍❤️‍👨", "👩‍❤️‍👩", "👨‍👩‍👦", "👨‍👩‍👧",
                "👨‍👩‍👧‍👦", "👨‍👩‍👦‍👦", "👨‍👩‍👧‍👧", "👨‍👨‍👦", "👨‍👨‍👧",
                "👨‍👨‍👧‍👦", "👨‍👨‍👦‍👦", "👨‍👨‍👧‍👧", "👩‍👩‍👦", "👩‍👩‍👧",
                "👩‍👩‍👧‍👦", "👩‍👩‍👦‍👦", "👩‍👩‍👧‍👧", "👨‍👦", "👨‍👦‍👦",
                "👨‍👧", "👨‍👧‍👦", "👨‍👧‍👧", "👩‍👦", "👩‍👦‍👦",
                "👩‍👧", "👩‍👧‍👦", "👩‍👧‍👧", "🗣️", "👤",
                "👥", "🫂", "👪", "🧑‍🧑‍🧒", "🧑‍🧑‍🧒‍🧒",
                "🧑‍🧒", "🧑‍🧒‍🧒", "👣",
            ]
        ),
        EmojiCategory(
            name: "Animals",
            icon: "🐶",
            emojis: [
                "🐵", "🐒", "🦍", "🦧", "🐶",
                "🐕", "🦮", "🐕‍🦺", "🐩", "🐺",
                "🦊", "🦝", "🐱", "🐈", "🐈‍⬛",
                "🦁", "🐯", "🐅", "🐆", "🐴",
                "🫎", "🫏", "🐎", "🦄", "🦓",
                "🦌", "🦬", "🐮", "🐂", "🐃",
                "🐄", "🐷", "🐖", "🐗", "🐽",
                "🐏", "🐑", "🐐", "🐪", "🐫",
                "🦙", "🦒", "🐘", "🦣", "🦏",
                "🦛", "🐭", "🐁", "🐀", "🐹",
                "🐰", "🐇", "🐿️", "🦫", "🦔",
                "🦇", "🐻", "🐻‍❄️", "🐨", "🐼",
                "🦥", "🦦", "🦨", "🦘", "🦡",
                "🐾", "🦃", "🐔", "🐓", "🐣",
                "🐤", "🐥", "🐦", "🐧", "🕊️",
                "🦅", "🦆", "🦢", "🦉", "🦤",
                "🪶", "🦩", "🦚", "🦜", "🪽",
                "🐦‍⬛", "🪿", "🐦‍🔥", "🐸", "🐊",
                "🐢", "🦎", "🐍", "🐲", "🐉",
                "🦕", "🦖", "🐳", "🐋", "🐬",
                "🦭", "🐟", "🐠", "🐡", "🦈",
                "🐙", "🐚", "🪸", "🪼", "🐌",
                "🦋", "🐛", "🐜", "🐝", "🪲",
                "🐞", "🦗", "🪳", "🕷️", "🕸️",
                "🦂", "🦟", "🪰", "🪱", "🦠",
                "💐", "🌸", "💮", "🪷", "🏵️",
                "🌹", "🥀", "🌺", "🌻", "🌼",
                "🌷", "🪻", "🌱", "🪴", "🌲",
                "🌳", "🌴", "🌵", "🌾", "🌿",
                "☘️", "🍀", "🍁", "🍂", "🍃",
                "🪹", "🪺", "🍄",
            ]
        ),
        EmojiCategory(
            name: "Food",
            icon: "🍔",
            emojis: [
                "🍇", "🍈", "🍉", "🍊", "🍋",
                "🍋‍🟩", "🍌", "🍍", "🥭", "🍎",
                "🍏", "🍐", "🍑", "🍒", "🍓",
                "🫐", "🥝", "🍅", "🫒", "🥥",
                "🥑", "🍆", "🥔", "🥕", "🌽",
                "🌶️", "🫑", "🥒", "🥬", "🥦",
                "🧄", "🧅", "🥜", "🫘", "🌰",
                "🫚", "🫛", "🍄‍🟫", "🍞", "🥐",
                "🥖", "🫓", "🥨", "🥯", "🥞",
                "🧇", "🧀", "🍖", "🍗", "🥩",
                "🥓", "🍔", "🍟", "🍕", "🌭",
                "🥪", "🌮", "🌯", "🫔", "🥙",
                "🧆", "🥚", "🍳", "🥘", "🍲",
                "🫕", "🥣", "🥗", "🍿", "🧈",
                "🧂", "🥫", "🍱", "🍘", "🍙",
                "🍚", "🍛", "🍜", "🍝", "🍠",
                "🍢", "🍣", "🍤", "🍥", "🥮",
                "🍡", "🥟", "🥠", "🥡", "🦀",
                "🦞", "🦐", "🦑", "🦪", "🍦",
                "🍧", "🍨", "🍩", "🍪", "🎂",
                "🍰", "🧁", "🥧", "🍫", "🍬",
                "🍭", "🍮", "🍯", "🍼", "🥛",
                "☕", "🫖", "🍵", "🍶", "🍾",
                "🍷", "🍸", "🍹", "🍺", "🍻",
                "🥂", "🥃", "🫗", "🥤", "🧋",
                "🧃", "🧉", "🧊", "🥢", "🍽️",
                "🍴", "🥄", "🔪", "🫙", "🏺",
            ]
        ),
        EmojiCategory(
            name: "Activities",
            icon: "⚽",
            emojis: [
                "🎃", "🎄", "🎆", "🎇", "🧨",
                "✨", "🎈", "🎉", "🎊", "🎋",
                "🎍", "🎎", "🎏", "🎐", "🎑",
                "🧧", "🎀", "🎁", "🎗️", "🎟️",
                "🎫", "🎖️", "🏆", "🏅", "🥇",
                "🥈", "🥉", "⚽", "⚾", "🥎",
                "🏀", "🏐", "🏈", "🏉", "🎾",
                "🥏", "🎳", "🏏", "🏑", "🏒",
                "🥍", "🏓", "🏸", "🥊", "🥋",
                "🥅", "⛳", "⛸️", "🎣", "🤿",
                "🎽", "🎿", "🛷", "🥌", "🎯",
                "🪀", "🪁", "🔫", "🎱", "🔮",
                "🪄", "🎮", "🕹️", "🎰", "🎲",
                "🧩", "🧸", "🪅", "🪩", "🪆",
                "♠️", "♥️", "♦️", "♣️", "♟️",
                "🃏", "🀄", "🎴", "🎭", "🖼️",
                "🎨", "🧵", "🪡", "🧶", "🪢",
            ]
        ),
        EmojiCategory(
            name: "Travel",
            icon: "✈️",
            emojis: [
                "🌍", "🌎", "🌏", "🌐", "🗺️",
                "🗾", "🧭", "🏔️", "⛰️", "🌋",
                "🗻", "🏕️", "🏖️", "🏜️", "🏝️",
                "🏞️", "🏟️", "🏛️", "🏗️", "🧱",
                "🪨", "🪵", "🛖", "🏘️", "🏚️",
                "🏠", "🏡", "🏢", "🏣", "🏤",
                "🏥", "🏦", "🏨", "🏩", "🏪",
                "🏫", "🏬", "🏭", "🏯", "🏰",
                "💒", "🗼", "🗽", "⛪", "🕌",
                "🛕", "🕍", "⛩️", "🕋", "⛲",
                "⛺", "🌁", "🌃", "🏙️", "🌄",
                "🌅", "🌆", "🌇", "🌉", "♨️",
                "🎠", "🛝", "🎡", "🎢", "💈",
                "🎪", "🚂", "🚃", "🚄", "🚅",
                "🚆", "🚇", "🚈", "🚉", "🚊",
                "🚝", "🚞", "🚋", "🚌", "🚍",
                "🚎", "🚐", "🚑", "🚒", "🚓",
                "🚔", "🚕", "🚖", "🚗", "🚘",
                "🚙", "🛻", "🚚", "🚛", "🚜",
                "🏎️", "🏍️", "🛵", "🦽", "🦼",
                "🛺", "🚲", "🛴", "🛹", "🛼",
                "🚏", "🛣️", "🛤️", "🛢️", "⛽",
                "🛞", "🚨", "🚥", "🚦", "🛑",
                "🚧", "⚓", "🛟", "⛵", "🛶",
                "🚤", "🛳️", "⛴️", "🛥️", "🚢",
                "✈️", "🛩️", "🛫", "🛬", "🪂",
                "💺", "🚁", "🚟", "🚠", "🚡",
                "🛰️", "🚀", "🛸", "🛎️", "🧳",
                "⌛", "⏳", "⌚", "⏰", "⏱️",
                "⏲️", "🕰️", "🕛", "🕧", "🕐",
                "🕜", "🕑", "🕝", "🕒", "🕞",
                "🕓", "🕟", "🕔", "🕠", "🕕",
                "🕡", "🕖", "🕢", "🕗", "🕣",
                "🕘", "🕤", "🕙", "🕥", "🕚",
                "🕦", "🌑", "🌒", "🌓", "🌔",
                "🌕", "🌖", "🌗", "🌘", "🌙",
                "🌚", "🌛", "🌜", "🌡️", "☀️",
                "🌝", "🌞", "🪐", "⭐", "🌟",
                "🌠", "🌌", "☁️", "⛅", "⛈️",
                "🌤️", "🌥️", "🌦️", "🌧️", "🌨️",
                "🌩️", "🌪️", "🌫️", "🌬️", "🌀",
                "🌈", "🌂", "☂️", "☔", "⛱️",
                "⚡", "❄️", "☃️", "⛄", "☄️",
                "🔥", "💧", "🌊",
            ]
        ),
        EmojiCategory(
            name: "Objects",
            icon: "💡",
            emojis: [
                "👓", "🕶️", "🥽", "🥼", "🦺",
                "👔", "👕", "👖", "🧣", "🧤",
                "🧥", "🧦", "👗", "👘", "🥻",
                "🩱", "🩲", "🩳", "👙", "👚",
                "🪭", "👛", "👜", "👝", "🛍️",
                "🎒", "🩴", "👞", "👟", "🥾",
                "🥿", "👠", "👡", "🩰", "👢",
                "🪮", "👑", "👒", "🎩", "🎓",
                "🧢", "🪖", "⛑️", "📿", "💄",
                "💍", "💎", "🔇", "🔈", "🔉",
                "🔊", "📢", "📣", "📯", "🔔",
                "🔕", "🎼", "🎵", "🎶", "🎙️",
                "🎚️", "🎛️", "🎤", "🎧", "📻",
                "🎷", "🪗", "🎸", "🎹", "🎺",
                "🎻", "🪕", "🥁", "🪘", "🪇",
                "🪈", "📱", "📲", "☎️", "📞",
                "📟", "📠", "🔋", "🪫", "🔌",
                "💻", "🖥️", "🖨️", "⌨️", "🖱️",
                "🖲️", "💽", "💾", "💿", "📀",
                "🧮", "🎥", "🎞️", "📽️", "🎬",
                "📺", "📷", "📸", "📹", "📼",
                "🔍", "🔎", "🕯️", "💡", "🔦",
                "🏮", "🪔", "📔", "📕", "📖",
                "📗", "📘", "📙", "📚", "📓",
                "📒", "📃", "📜", "📄", "📰",
                "🗞️", "📑", "🔖", "🏷️", "💰",
                "🪙", "💴", "💵", "💶", "💷",
                "💸", "💳", "🧾", "💹", "✉️",
                "📧", "📨", "📩", "📤", "📥",
                "📦", "📫", "📪", "📬", "📭",
                "📮", "🗳️", "✏️", "✒️", "🖋️",
                "🖊️", "🖌️", "🖍️", "📝", "💼",
                "📁", "📂", "🗂️", "📅", "📆",
                "🗒️", "🗓️", "📇", "📈", "📉",
                "📊", "📋", "📌", "📍", "📎",
                "🖇️", "📏", "📐", "✂️", "🗃️",
                "🗄️", "🗑️", "🔒", "🔓", "🔏",
                "🔐", "🔑", "🗝️", "🔨", "🪓",
                "⛏️", "⚒️", "🛠️", "🗡️", "⚔️",
                "💣", "🪃", "🏹", "🛡️", "🪚",
                "🔧", "🪛", "🔩", "⚙️", "🗜️",
                "⚖️", "🦯", "🔗", "⛓️‍💥", "⛓️",
                "🪝", "🧰", "🧲", "🪜", "⚗️",
                "🧪", "🧫", "🧬", "🔬", "🔭",
                "📡", "💉", "🩸", "💊", "🩹",
                "🩼", "🩺", "🩻", "🚪", "🛗",
                "🪞", "🪟", "🛏️", "🛋️", "🪑",
                "🚽", "🪠", "🚿", "🛁", "🪤",
                "🪒", "🧴", "🧷", "🧹", "🧺",
                "🧻", "🪣", "🧼", "🫧", "🪥",
                "🧽", "🧯", "🛒", "🚬", "⚰️",
                "🪦", "⚱️", "🧿", "🪬", "🗿",
                "🪧", "🪪",
            ]
        ),
        EmojiCategory(
            name: "Symbols",
            icon: "♻️",
            emojis: [
                "🏧", "🚮", "🚰", "♿", "🚹",
                "🚺", "🚻", "🚼", "🚾", "🛂",
                "🛃", "🛄", "🛅", "⚠️", "🚸",
                "⛔", "🚫", "🚳", "🚭", "🚯",
                "🚱", "🚷", "📵", "🔞", "☢️",
                "☣️", "⬆️", "↗️", "➡️", "↘️",
                "⬇️", "↙️", "⬅️", "↖️", "↕️",
                "↔️", "↩️", "↪️", "⤴️", "⤵️",
                "🔃", "🔄", "🔙", "🔚", "🔛",
                "🔜", "🔝", "🛐", "⚛️", "🕉️",
                "✡️", "☸️", "☯️", "✝️", "☦️",
                "☪️", "☮️", "🕎", "🔯", "🪯",
                "♈", "♉", "♊", "♋", "♌",
                "♍", "♎", "♏", "♐", "♑",
                "♒", "♓", "⛎", "🔀", "🔁",
                "🔂", "▶️", "⏩", "⏭️", "⏯️",
                "◀️", "⏪", "⏮️", "🔼", "⏫",
                "🔽", "⏬", "⏸️", "⏹️", "⏺️",
                "⏏️", "🎦", "🔅", "🔆", "📶",
                "🛜", "📳", "📴", "♀️", "♂️",
                "⚧️", "✖️", "➕", "➖", "➗",
                "🟰", "♾️", "‼️", "⁉️", "❓",
                "❔", "❕", "❗", "〰️", "💱",
                "💲", "⚕️", "♻️", "⚜️", "🔱",
                "📛", "🔰", "⭕", "✅", "☑️",
                "✔️", "❌", "❎", "➰", "➿",
                "〽️", "✳️", "✴️", "❇️", "©️",
                "®️", "™️", "#️⃣", "*️⃣", "0️⃣",
                "1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣",
                "6️⃣", "7️⃣", "8️⃣", "9️⃣", "🔟",
                "🔠", "🔡", "🔢", "🔣", "🔤",
                "🅰️", "🆎", "🅱️", "🆑", "🆒",
                "🆓", "ℹ️", "🆔", "Ⓜ️", "🆕",
                "🆖", "🅾️", "🆗", "🅿️", "🆘",
                "🆙", "🆚", "🈁", "🈂️", "🈷️",
                "🈶", "🈯", "🉐", "🈹", "🈚",
                "🈲", "🉑", "🈸", "🈴", "🈳",
                "㊗️", "㊙️", "🈺", "🈵", "🔴",
                "🟠", "🟡", "🟢", "🔵", "🟣",
                "🟤", "⚫", "⚪", "🟥", "🟧",
                "🟨", "🟩", "🟦", "🟪", "🟫",
                "⬛", "⬜", "◼️", "◻️", "◾",
                "◽", "▪️", "▫️", "🔶", "🔷",
                "🔸", "🔹", "🔺", "🔻", "💠",
                "🔘", "🔳", "🔲",
            ]
        ),
        EmojiCategory(
            name: "Flags",
            icon: "🏴‍☠️",
            emojis: [
                "🏁", "🚩", "🎌", "🏴", "🏳️",
                "🏳️‍🌈", "🏳️‍⚧️", "🏴‍☠️", "🇦🇨", "🇦🇩",
                "🇦🇪", "🇦🇫", "🇦🇬", "🇦🇮", "🇦🇱",
                "🇦🇲", "🇦🇴", "🇦🇶", "🇦🇷", "🇦🇸",
                "🇦🇹", "🇦🇺", "🇦🇼", "🇦🇽", "🇦🇿",
                "🇧🇦", "🇧🇧", "🇧🇩", "🇧🇪", "🇧🇫",
                "🇧🇬", "🇧🇭", "🇧🇮", "🇧🇯", "🇧🇱",
                "🇧🇲", "🇧🇳", "🇧🇴", "🇧🇶", "🇧🇷",
                "🇧🇸", "🇧🇹", "🇧🇻", "🇧🇼", "🇧🇾",
                "🇧🇿", "🇨🇦", "🇨🇨", "🇨🇩", "🇨🇫",
                "🇨🇬", "🇨🇭", "🇨🇮", "🇨🇰", "🇨🇱",
                "🇨🇲", "🇨🇳", "🇨🇴", "🇨🇵", "🇨🇷",
                "🇨🇺", "🇨🇻", "🇨🇼", "🇨🇽", "🇨🇾",
                "🇨🇿", "🇩🇪", "🇩🇬", "🇩🇯", "🇩🇰",
                "🇩🇲", "🇩🇴", "🇩🇿", "🇪🇦", "🇪🇨",
                "🇪🇪", "🇪🇬", "🇪🇭", "🇪🇷", "🇪🇸",
                "🇪🇹", "🇪🇺", "🇫🇮", "🇫🇯", "🇫🇰",
                "🇫🇲", "🇫🇴", "🇫🇷", "🇬🇦", "🇬🇧",
                "🇬🇩", "🇬🇪", "🇬🇫", "🇬🇬", "🇬🇭",
                "🇬🇮", "🇬🇱", "🇬🇲", "🇬🇳", "🇬🇵",
                "🇬🇶", "🇬🇷", "🇬🇸", "🇬🇹", "🇬🇺",
                "🇬🇼", "🇬🇾", "🇭🇰", "🇭🇲", "🇭🇳",
                "🇭🇷", "🇭🇹", "🇭🇺", "🇮🇨", "🇮🇩",
                "🇮🇪", "🇮🇱", "🇮🇲", "🇮🇳", "🇮🇴",
                "🇮🇶", "🇮🇷", "🇮🇸", "🇮🇹", "🇯🇪",
                "🇯🇲", "🇯🇴", "🇯🇵", "🇰🇪", "🇰🇬",
                "🇰🇭", "🇰🇮", "🇰🇲", "🇰🇳", "🇰🇵",
                "🇰🇷", "🇰🇼", "🇰🇾", "🇰🇿", "🇱🇦",
                "🇱🇧", "🇱🇨", "🇱🇮", "🇱🇰", "🇱🇷",
                "🇱🇸", "🇱🇹", "🇱🇺", "🇱🇻", "🇱🇾",
                "🇲🇦", "🇲🇨", "🇲🇩", "🇲🇪", "🇲🇫",
                "🇲🇬", "🇲🇭", "🇲🇰", "🇲🇱", "🇲🇲",
                "🇲🇳", "🇲🇴", "🇲🇵", "🇲🇶", "🇲🇷",
                "🇲🇸", "🇲🇹", "🇲🇺", "🇲🇻", "🇲🇼",
                "🇲🇽", "🇲🇾", "🇲🇿", "🇳🇦", "🇳🇨",
                "🇳🇪", "🇳🇫", "🇳🇬", "🇳🇮", "🇳🇱",
                "🇳🇴", "🇳🇵", "🇳🇷", "🇳🇺", "🇳🇿",
                "🇴🇲", "🇵🇦", "🇵🇪", "🇵🇫", "🇵🇬",
                "🇵🇭", "🇵🇰", "🇵🇱", "🇵🇲", "🇵🇳",
                "🇵🇷", "🇵🇸", "🇵🇹", "🇵🇼", "🇵🇾",
                "🇶🇦", "🇷🇪", "🇷🇴", "🇷🇸", "🇷🇺",
                "🇷🇼", "🇸🇦", "🇸🇧", "🇸🇨", "🇸🇩",
                "🇸🇪", "🇸🇬", "🇸🇭", "🇸🇮", "🇸🇯",
                "🇸🇰", "🇸🇱", "🇸🇲", "🇸🇳", "🇸🇴",
                "🇸🇷", "🇸🇸", "🇸🇹", "🇸🇻", "🇸🇽",
                "🇸🇾", "🇸🇿", "🇹🇦", "🇹🇨", "🇹🇩",
                "🇹🇫", "🇹🇬", "🇹🇭", "🇹🇯", "🇹🇰",
                "🇹🇱", "🇹🇲", "🇹🇳", "🇹🇴", "🇹🇷",
                "🇹🇹", "🇹🇻", "🇹🇼", "🇹🇿", "🇺🇦",
                "🇺🇬", "🇺🇲", "🇺🇳", "🇺🇸", "🇺🇾",
                "🇺🇿", "🇻🇦", "🇻🇨", "🇻🇪", "🇻🇬",
                "🇻🇮", "🇻🇳", "🇻🇺", "🇼🇫", "🇼🇸",
                "🇽🇰", "🇾🇪", "🇾🇹", "🇿🇦", "🇿🇲",
                "🇿🇼", "🏴󠁧󠁢󠁥󠁮󠁧󠁿", "🏴󠁧󠁢󠁳󠁣󠁴󠁿", "🏴󠁧󠁢󠁷󠁬󠁳󠁿",
            ]
        )
    ]
    // END GENERATED

    /// The pre-parity default (the old Android-ported 16). Users who never
    /// customized carry it forward in their persisted state; migrate them to
    /// the canonical set, mirroring Android's default-list upgrade.
    static let previousDefaultQuickReactions: [String] = [
        "❤️", "🔥", "👍", "🤙", "😋", "🤤", "🤩", "💯", "🙏", "🍳", "🤌", "🧑‍🍳", "😍", "🌶️", "🥗", "🍽️"
    ]

    /// Persisted quick-reaction lists pass through untouched unless they are
    /// exactly the prior default — that means the user never customized, so
    /// they get the current canonical set.
    static func upgradingPriorDefault(_ stored: [String]) -> [String] {
        stored == previousDefaultQuickReactions ? defaultQuickReactions : stored
    }

    /// Flat list of every unicode emoji across categories, in display order.
    static let allEmojis: [String] = categories.flatMap { $0.emojis }

    /// Lazy lowercased Unicode-name lookup keyed by emoji character. Built on
    /// first access using `String.applyingTransform(.toUnicodeName, ...)` so we
    /// don't ship a hardcoded keyword table — the OS already has the data.
    /// Used by `searchEmojis(_:)` for the library's search field.
    static let nameByEmoji: [String: String] = {
        var map: [String: String] = [:]
        for emoji in allEmojis {
            // `applyingTransform(.toUnicodeName)` returns sequences like
            // `\N{FACE WITH TEARS OF JOY}` — keep the words, drop the wrapper.
            guard let raw = emoji.applyingTransform(.toUnicodeName, reverse: false) else { continue }
            let cleaned = raw
                .replacingOccurrences(of: "\\N{", with: "")
                .replacingOccurrences(of: "}", with: " ")
                .lowercased()
            map[emoji] = cleaned
        }
        return map
    }()

    /// Supplemental keyword aliases for terms the Unicode CLDR keyword
    /// data (loaded by `CldrEmojiKeywords`) genuinely doesn't ship.
    /// CLDR already covers the standard descriptions (love, fire, laugh,
    /// thumbs, etc.) AND most slang (lol, lmao, lit, ily, etc.), so this
    /// table is intentionally small — only the nostr-culture, internet
    /// shorthand, and explicit-override entries that aren't in CLDR's
    /// English annotations.
    ///
    /// When extending: check `CldrEmojiKeywords.keywordsByEmoji[e]` first
    /// to avoid duplicating coverage.
    static let keywordAliases: [String: [String]] = [
        // Internet slang / shorthand not in CLDR
        "💀": ["ded"],
        "😏": ["sus", "suspicious"],
        "🤨": ["sus", "suspicious"],
        "🥹": ["pleading"],
        // Nostr-culture
        "🐸": ["pepe"],
        // Useful overrides where the CLDR keyword set is sparse or where
        // we want the alias to rank ahead of unrelated Unicode-name hits
        "✅": ["ok", "yes"],
        "❌": ["x", "no"],
        "🚀": ["moon", "fly"],
        "🔥": ["af"],
        "👀": ["shifty", "watching"],
        // Common short forms
        "💯": ["100", "hundred"],
        "🆗": ["ok"],
        "🆕": ["new"],
        "⭕": ["circle", "o", "ring"],
        // "italian" — gesture nickname plus food/flag CLDR doesn't cross-list
        // under this term (flag: Italy has no CLDR keyword entry at all)
        "🤌": ["italian", "italian hand", "italian hands"],
        "🍕": ["italian"],
        "🍝": ["italian"],
        "🇮🇹": ["italian", "italy"]
    ]

    /// Reverse index used by `searchEmojis`. Built once on first access so
    /// "lol" → 😂 / 🤣 lookups don't iterate the alias map.
    static let emojisByAlias: [String: [String]] = {
        var map: [String: [String]] = [:]
        for (emoji, aliases) in keywordAliases {
            for alias in aliases {
                map[alias, default: []].append(emoji)
            }
        }
        return map
    }()

    /// Returns every emoji whose CLDR keyword, hand-curated alias, or
    /// Unicode name matches `query` (case-insensitive substring match).
    /// Empty query returns an empty list — callers should short-circuit
    /// and show the categorized view instead.
    ///
    /// Match order is deliberate:
    /// 1. Hand-curated `keywordAliases` — covers nostr-culture and slang
    ///    that CLDR doesn't ship ("pepe", "lol", "ded", etc.).
    /// 2. CLDR keywords — the comprehensive 1500-entry index from
    ///    Unicode's official annotations data.
    /// 3. Unicode name substring — last-resort catch-all.
    ///
    /// Filtering to entries that appear in the rendered `allEmojis` set
    /// keeps the catalog as the source of truth — CLDR has many emoji
    /// our categories don't include (e.g. skin-tone modifiers as
    /// standalone entries) which we don't want surfaced as standalone
    /// results.
    static func searchEmojis(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let renderable = Set(allEmojis)
        var seen = Set<String>()
        var ordered: [String] = []

        for (alias, emojis) in emojisByAlias where alias.contains(q) {
            for emoji in emojis where renderable.contains(emoji) && seen.insert(emoji).inserted {
                ordered.append(emoji)
            }
        }
        for (keyword, emojis) in CldrEmojiKeywords.emojisByKeyword where keyword.contains(q) {
            for emoji in emojis where renderable.contains(emoji) && seen.insert(emoji).inserted {
                ordered.append(emoji)
            }
        }
        for emoji in allEmojis where (nameByEmoji[emoji] ?? "").contains(q) {
            if seen.insert(emoji).inserted { ordered.append(emoji) }
        }
        return ordered
    }
}
