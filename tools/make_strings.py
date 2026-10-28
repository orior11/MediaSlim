#!/usr/bin/env python3
"""Generates App/Resources/Localizable.xcstrings and InfoPlist.xcstrings (English + Hebrew).

Keys are the English source strings exactly as SwiftUI looks them up (interpolations become
%lld for integers and %@ for strings). Run from the repository root:  python3 tools/make_strings.py
"""
import json
import pathlib

HE = {
    # Onboarding
    "Free up space without losing quality": "לפנות מקום בלי לוותר על איכות",
    "MediaSlim re-saves your photos and videos more efficiently. They look the same and take about half the space.":
        "MediaSlim שומרת מחדש את התמונות והסרטונים שלך בצורה יעילה יותר. הם נראים אותו דבר ותופסים בערך חצי מקום.",
    "Everything stays on your iPhone": "הכול נשאר באייפון שלך",
    "No uploads, no accounts, no tracking. MediaSlim has no servers.": "בלי העלאות, בלי חשבונות ובלי מעקב. ל‑MediaSlim אין שרתים.",
    "Nothing changes without you": "שום דבר לא משתנה בלי האישור שלכם",
    "You choose what to shrink, and you confirm before any original is deleted.": "אתם בוחרים מה לכווץ ומאשרים לפני שמקור כלשהו נמחק.",
    "Originals can be restored": "אפשר לשחזר את המקורות",
    "Deleted originals stay in Recently Deleted in Photos for 30 days.": "מקורות שנמחקו נשארים ב'נמחקו לאחרונה' באפליקציית התמונות 30 יום.",
    "Photo access is off": "הגישה לתמונות כבויה",
    "Turn on access to all photos for MediaSlim in Settings.": "יש להפעיל בהגדרות גישה לכל התמונות עבור MediaSlim.",
    "Open Settings": "פתיחת ההגדרות",
    "Allow Photo Access": "אישור גישה לתמונות",
    "Shows the system permission dialog.": "מציג את חלון ההרשאה של המערכת.",
    "MediaSlim asks for full access because replacing a file means reading the original and then deleting it. You can also share only some items.":
        "MediaSlim מבקשת גישה מלאה, כי החלפת קובץ דורשת לקרוא את המקור ואחר כך למחוק אותו. אפשר גם לשתף רק חלק מהפריטים.",

    # Home
    "MediaSlim": "MediaSlim",
    "Settings": "הגדרות",
    "Photo access needed": "נדרשת גישה לתמונות",
    "MediaSlim can't see your photos. Allow access in Settings to continue.": "MediaSlim לא רואה את התמונות שלך. כדי להמשיך יש לאשר גישה בהגדרות.",
    "Limited access": "גישה מוגבלת",
    "MediaSlim sees only the items you shared with it. You can share more in Settings.": "MediaSlim רואה רק את הפריטים ששיתפתם איתה. אפשר לשתף עוד בהגדרות.",
    "Ready to free space": "מוכן לפנות מקום",
    "%lld compressed copies are safely in your library. Delete the originals to free %@.":
        "%1$lld עותקים מכווצים שמורים בבטחה בספרייה. מחיקת המקורות תפנה %2$@.",
    "Delete Originals": "מחיקת המקורות",
    "Keep Both": "שמירת שניהם",
    "Unfinished run": "סבב שלא הסתיים",
    "%lld items were not processed yet. Nothing was lost.": "%lld פריטים עדיין לא עובדו. שום דבר לא אבד.",
    "Continue": "המשך",
    "Discard": "ביטול הסבב",
    "What should MediaSlim shrink?": "מה לכווץ?",
    "You'll see an estimate before anything changes.": "לפני שמשהו משתנה תוצג הערכה.",
    "Whole Library": "כל הספרייה",
    "Every photo and video": "כל התמונות והסרטונים",
    "An Album": "אלבום",
    "Pick one album": "בחירת אלבום אחד",
    "Choose Items": "בחירת פריטים",
    "Select specific photos and videos": "בחירה של תמונות וסרטונים מסוימים",
    "Space freed so far": "מקום שפונה עד עכשיו",
    "History": "היסטוריה",
    "Loading albums…": "טוען אלבומים…",
    "No Albums": "אין אלבומים",
    "Albums you create in Photos appear here.": "אלבומים שיצרתם באפליקציית התמונות יופיעו כאן.",
    "%@, %lld items": "%1$@, %2$lld פריטים",
    "Albums": "אלבומים",
    "Cancel": "ביטול",

    # Review
    "Looking through your library…": "סורק את הספרייה…",
    "Couldn't read the library": "לא ניתן לקרוא את הספרייה",
    "Review": "סקירה",
    "Nothing to shrink here": "אין כאן מה לכווץ",
    "These items are already efficient, or are types MediaSlim leaves as they are.": "הפריטים האלה כבר יעילים, או מסוגים ש‑MediaSlim משאירה כמו שהם.",
    "Estimated space to free": "הערכת המקום שיתפנה",
    "%lld photos and %lld videos, %@ in total.": "%1$lld תמונות ו‑%2$lld סרטונים, %3$@ בסך הכול.",
    "The real result is measured for every file. Anything that doesn't pass the quality check is left untouched.":
        "התוצאה האמיתית נמדדת לכל קובץ. קובץ שלא עובר את בדיקת האיכות נשאר כמו שהוא.",
    "Quality": "איכות",
    "Recommended": "מומלץ",
    "Originals": "המקורות",
    "Replace originals": "החלפת המקורות",
    "The smaller copy takes the original's place, with the same date, location and albums. After you confirm, originals move to Recently Deleted for 30 days.":
        "העותק הקטן נכנס במקום המקור, עם אותו תאריך, מיקום ואלבומים. אחרי אישור, המקורות עוברים ל'נמחקו לאחרונה' ל‑30 יום.",
    "Last time": "בפעם הקודמת",
    "Keep both": "שמירת שניהם",
    "The smaller copy is added to the MediaSlim album and nothing is deleted. Space is freed only when you delete originals yourself.":
        "העותק הקטן מתווסף לאלבום MediaSlim ושום דבר לא נמחק. מקום יתפנה רק כשמוחקים את המקורות ידנית.",
    "Start": "התחלה",
    "Choose what happens to the originals first.": "קודם יש לבחור מה יקרה למקורות.",
    "Choose what happens to the originals to continue.": "כדי להמשיך, יש לבחור מה יקרה למקורות.",
    "Keep MediaSlim open, or connect a charger and it continues in the background.": "השאירו את MediaSlim פתוחה, או חברו מטען והעבודה תימשך ברקע.",
    "%lld items will be left as they are": "%lld פריטים יישארו כמו שהם",

    # Quality levels
    "Maximum quality": "איכות מרבית",
    "Balanced": "מאוזן",
    "Maximum savings": "חיסכון מרבי",
    "Practically identical to the original, even when zoomed in. Frees less space.": "כמעט זהה למקור, גם בהגדלה. מפנה פחות מקום.",
    "No visible difference when viewing normally. Recommended.": "אין הבדל נראה בצפייה רגילה. מומלץ.",
    "Frees the most space. Small differences may show when zooming in.": "מפנה הכי הרבה מקום. בהגדלה ייתכנו הבדלים קטנים.",

    # Skip reasons
    "Live Photos": "תמונות Live",
    "Edited in Photos": "נערכו באפליקציית התמונות",
    "RAW photos": "תמונות RAW",
    "Slow-motion videos": "סרטוני הילוך איטי",
    "Cinematic videos": "סרטוני מצב קולנועי",
    "Spatial photos and videos": "תמונות וסרטונים מרחביים",
    "Shared or synced items": "פריטים משותפים או מסונכרנים",
    "Other file formats": "פורמטים אחרים",
    "Already small": "כבר קטנים",
    "Already compressed": "כבר דחוסים",
    "Already shrunk by MediaSlim": "כבר כווצו ב‑MediaSlim",
    "Stored only in iCloud": "שמורים רק ב‑iCloud",
    "Little to gain": "חיסכון זניח",
    "The photo and its short video must stay linked. Support is planned.": "התמונה והסרטון הקצר שלה חייבים להישאר מקושרים. התמיכה מתוכננת.",
    "Replacing them would remove your edit history.": "החלפה שלהם תמחק את היסטוריית העריכה.",
    "RAW files are kept as they are for editing.": "קובצי RAW נשמרים כמו שהם לצורך עריכה.",
    "Slow-motion timing would be lost.": "תזמון ההילוך האיטי היה הולך לאיבוד.",
    "The editable focus track would be lost.": "מסלול הפוקוס הניתן לעריכה היה הולך לאיבוד.",
    "Depth for Apple Vision Pro would be lost.": "העומק עבור Apple Vision Pro היה הולך לאיבוד.",
    "These belong to a shared album or another device.": "הם שייכים לאלבום משותף או למכשיר אחר.",
    "Only HEIC, JPEG, PNG and standard video are handled.": "רק HEIC,‏ JPEG,‏ PNG וסרטונים רגילים מטופלים.",
    "Shrinking them would free almost nothing.": "כיווץ שלהם כמעט לא יפנה מקום.",
    "Usually received through a messaging app. Shrinking again would lower quality.": "בדרך כלל התקבלו באפליקציית הודעות. כיווץ נוסף יפגע באיכות.",
    "Shrinking twice would lower quality.": "כיווץ כפול יפגע באיכות.",
    "Turn on iCloud downloads in Settings to include them.": "כדי לכלול אותם, יש להפעיל בהגדרות הורדה מ‑iCloud.",
    "Less than a tenth of the size could be saved at your quality setting.": "בהגדרת האיכות שנבחרה אפשר היה לחסוך פחות מעשירית מהגודל.",
    "Something went wrong while reading your library. Nothing was changed.": "משהו השתבש בקריאת הספרייה. שום דבר לא שונה.",
    "MediaSlim needs access to your photos. You can allow it in Settings.": "MediaSlim צריכה גישה לתמונות שלך. אפשר לאשר אותה בהגדרות.",
    "That album or item is no longer in your library.": "האלבום או הפריט כבר לא נמצאים בספרייה.",
    "These items are stored only in iCloud.": "הפריטים האלה שמורים רק ב‑iCloud.",

    # Pause reasons
    "Paused by you.": "הושהה ידנית.",
    "Your iPhone is warm. MediaSlim continues when it cools down.": "האייפון חם. MediaSlim תמשיך כשהוא יתקרר.",
    "Low Power Mode is on. Turn it off or connect a charger to continue.": "מצב חיסכון בסוללה פעיל. כדי להמשיך, כבו אותו או חברו מטען.",
    "Space is almost full. Delete the originals processed so far to continue.": "האחסון כמעט מלא. כדי להמשיך, מחקו את המקורות שכבר עובדו.",

    # Processing
    "Done": "סיום",
    "Shrinking": "מכווץ",
    "%lld of %lld": "%1$lld מתוך %2$lld",
    "%@ saved so far": "נחסכו עד עכשיו %@",
    "Progress": "התקדמות",
    "%lld of %lld done. %@ saved so far.": "%1$lld מתוך %2$lld הושלמו. נחסכו עד עכשיו %3$@.",
    "Paused": "מושהה",
    "Space is running low": "האחסון עומד להיגמר",
    "Delete the originals processed so far to make room. You'll confirm in the next step.": "מחקו את המקורות שכבר עובדו כדי לפנות מקום. האישור יגיע בשלב הבא.",
    "Delete Processed Originals": "מחיקת המקורות שעובדו",
    "Resume": "המשך",
    "Pause": "השהיה",
    "Stop": "עצירה",
    "Files are replaced only after the smaller copy is saved and checked.": "קבצים מוחלפים רק אחרי שהעותק הקטן נשמר ונבדק.",
    "Stop now?": "לעצור עכשיו?",
    "Keep Going": "להמשיך",
    "Files already done stay done. Nothing is lost.": "קבצים שכבר טופלו נשארים כך. שום דבר לא אובד.",
    "Working on a photo": "מעבד תמונה",
    "Working on a video": "מעבד סרטון",

    # Results
    "Shrunk": "כווצו",
    "Left as is": "נשארו כמו שהם",
    "Couldn't process": "לא עובדו",
    "Stopped": "נעצר",
    "All done": "הכול הושלם",
    "Space freed": "מקום שפונה",
    "Smaller copies save": "העותקים הקטנים חוסכים",
    "%@ smaller on average for the files that were shrunk.": "בממוצע, הקבצים שכווצו קטנים ב‑%@.",
    "Both versions kept": "שתי הגרסאות נשמרו",
    "The smaller copies are in the MediaSlim album. Your originals are untouched.": "העותקים הקטנים נמצאים באלבום MediaSlim. המקורות לא שונו.",
    "Waiting for your confirmation": "ממתין לאישור",
    "iOS asks you to approve deleting the originals.": "iOS יבקש לאשר את מחיקת המקורות.",
    "Originals moved to Recently Deleted": "המקורות הועברו ל'נמחקו לאחרונה'",
    "%lld originals can be restored from Recently Deleted in Photos for 30 days. After that, iOS removes them for good.":
        "אפשר לשחזר %lld מקורות מ'נמחקו לאחרונה' באפליקציית התמונות במשך 30 יום. אחרי זה iOS מוחק אותם לצמיתות.",
    "Originals kept": "המקורות נשמרו",
    "You chose not to delete %lld originals, so no space was freed yet. Both versions are in your library.":
        "בחרתם לא למחוק %lld מקורות, ולכן עוד לא התפנה מקום. שתי הגרסאות נמצאות בספרייה.",
    "Originals not deleted": "המקורות לא נמחקו",
    "Some originals couldn't be deleted. Nothing was lost; you can try again from the home screen.":
        "חלק מהמקורות לא נמחקו. שום דבר לא אבד; אפשר לנסות שוב מהמסך הראשי.",

    # History
    "No History Yet": "אין עדיין היסטוריה",
    "Finished runs appear here.": "סבבים שהסתיימו יופיעו כאן.",
    "%@ saved from %lld items": "נחסכו %1$@ מ‑%2$lld פריטים",
    "%lld left as they were": "%lld נשארו כמו שהיו",

    # Settings
    "Default quality": "איכות ברירת מחדל",
    "Photos": "תמונות",
    "Videos": "סרטונים",
    "Include": "לכלול",
    "Download from iCloud when needed": "הורדה מ‑iCloud בעת הצורך",
    "If an original is stored only in iCloud, the Photos app downloads it first. MediaSlim itself never connects to the internet.":
        "אם מקור שמור רק ב‑iCloud, אפליקציית התמונות מורידה אותו קודם. MediaSlim עצמה אף פעם לא מתחברת לאינטרנט.",
    "Continue while charging": "המשך בזמן טעינה",
    "If you leave the app during a run, iOS can finish it later while your iPhone charges. Originals are deleted only after you confirm.":
        "אם יוצאים מהאפליקציה באמצע סבב, iOS יכול לסיים אותו מאוחר יותר בזמן שהאייפון נטען. מקורות נמחקים רק אחרי אישור.",
    "All processing happens on this iPhone.": "כל העיבוד מתבצע באייפון הזה.",
    "No accounts, servers, ads or analytics.": "בלי חשבונות, שרתים, פרסומות או ניתוח נתונים.",
    "Working files are encrypted and deleted after each item.": "קובצי עבודה מוצפנים ונמחקים אחרי כל פריט.",
    "Erase App Records": "מחיקת נתוני האפליקציה",
    "Privacy": "פרטיות",
    "Erasing removes MediaSlim's history and settings. Your photos and videos are not touched.": "המחיקה מסירה את ההיסטוריה וההגדרות של MediaSlim. התמונות והסרטונים שלך לא נפגעים.",
    "Version": "גרסה",
    "Erase app records?": "למחוק את נתוני האפליקציה?",
    "Erase": "מחיקה",
    "Your photos and videos are not touched.": "התמונות והסרטונים שלך לא נפגעים.",

    # Spoken announcements (String(localized:))
    "Started. Large files go first.": "התחלנו. קבצים גדולים קודם.",
    "Paused.": "מושהה.",
    "Resumed.": "ממשיך.",
    "Done. Saved %@.": "הסתיים. נחסכו %@.",
    "%lld of %lld done. %@ saved.": "%1$lld מתוך %2$lld הושלמו. נחסכו %3$@.",
}

COMMENTS = {
    "Done. Saved %@.": "Spoken when a run ends",
    "%lld of %lld done. %@ saved.": "Spoken progress update",
}

INFO_PLIST_HE = {
    "CFBundleDisplayName": ("MediaSlim", "MediaSlim"),
    "NSPhotoLibraryUsageDescription": (
        "MediaSlim reads your photos and videos to save smaller copies of them on this iPhone. Nothing leaves your device.",
        "MediaSlim קוראת את התמונות והסרטונים שלך כדי לשמור מהם עותקים קטנים יותר באייפון הזה. שום דבר לא יוצא מהמכשיר.",
    ),
    "NSPhotoLibraryAddUsageDescription": (
        "MediaSlim saves the smaller copies of your photos and videos to your library.",
        "MediaSlim שומרת בספרייה את העותקים הקטנים של התמונות והסרטונים שלך.",
    ),
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def catalog(strings):
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def main():
    root = pathlib.Path(__file__).resolve().parent.parent / "App" / "Resources"
    strings = {}
    for key, he in HE.items():
        entry = {"localizations": {"he": unit(he)}}
        if key in COMMENTS:
            entry["comment"] = COMMENTS[key]
        strings[key] = entry
    (root / "Localizable.xcstrings").write_text(json.dumps(catalog(strings), ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    info = {}
    for key, (en, he) in INFO_PLIST_HE.items():
        info[key] = {"extractionState": "manual", "localizations": {"en": unit(en), "he": unit(he)}}
    (root / "InfoPlist.xcstrings").write_text(json.dumps(catalog(info), ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(f"{len(strings)} app strings, {len(info)} Info.plist strings")


if __name__ == "__main__":
    main()
