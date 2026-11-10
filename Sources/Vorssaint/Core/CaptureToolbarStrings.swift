// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Localized strings for the capture toolbar, laid out like the system's
/// own (Command-Shift-5): its modes, its Options menu, the floating
/// thumbnail a recording leaves behind and the controls that stop one.
struct CaptureToolbarStrings {
    let optionsButton: String
    let captureButton: String
    let recordButton: String
    let closeButton: String
    let captureScreen: String
    let captureWindow: String
    let capturePortion: String
    let recordScreen: String
    let recordPortion: String
    let markupButton: String
    let timerLabel: String
    let timerNone: String
    let copyToClipboardToggle: String
    let clipboardOnlyChoice: String
    let copyToClipboardCaption: String
    let floatingThumbnailToggle: String
    let floatingThumbnailCaption: String
    let showClicksToggle: String
    let showClicksCaption: String
    let rememberSelectionToggle: String
    let showInFinder: String
    let stopHint: String
}

extension FeatureStrings {
    static func captureToolbar(_ language: AppLanguage) -> CaptureToolbarStrings {
        switch language {
        case .enUS: return .enUS
        case .ptBR: return .ptBR
        case .tr: return .tr
        case .ru: return .ru
        case .es: return .es
        case .sk: return .sk
        case .de: return .de
        case .fr: return .fr
        case .it: return .it
        case .ja: return .ja
        case .ko: return .ko
        case .zhHans: return .zhHans
        case .zhTW: return .zhTW
        case .zhHK: return .zhHK
        case .uk: return .uk
        }
    }
}

extension CaptureToolbarStrings {
    static let enUS = CaptureToolbarStrings(
        optionsButton: "Options",
        captureButton: "Capture",
        recordButton: "Record",
        closeButton: "Close",
        captureScreen: "Capture entire screen",
        captureWindow: "Capture selected window",
        capturePortion: "Capture selected portion",
        recordScreen: "Record entire screen",
        recordPortion: "Record selected portion",
        markupButton: "Markup screenshot",
        timerLabel: "Timer",
        timerNone: "None",
        copyToClipboardToggle: "Copy to clipboard",
        clipboardOnlyChoice: "Clipboard only",
        copyToClipboardCaption: "Every screenshot and recording is saved and also put on the clipboard as a file, ready to paste into any app.",
        floatingThumbnailToggle: "Show floating thumbnail",
        floatingThumbnailCaption: "After you stop, the recording waits in a corner for a few seconds. Click it to trim and edit, drag it into an app, or let it save by itself.",
        showClicksToggle: "Show mouse clicks",
        showClicksCaption: "A recording saved without the editor marks every click with a ring.",
        rememberSelectionToggle: "Remember last selection",
        showInFinder: "Show in Finder",
        stopHint: "Stop a recording from the menu bar or with ⌃⌘⎋."
    )

    static let ptBR = CaptureToolbarStrings(
        optionsButton: "Opções",
        captureButton: "Capturar",
        recordButton: "Gravar",
        closeButton: "Fechar",
        captureScreen: "Capturar a tela inteira",
        captureWindow: "Capturar a janela selecionada",
        capturePortion: "Capturar a parte selecionada",
        recordScreen: "Gravar a tela inteira",
        recordPortion: "Gravar a parte selecionada",
        markupButton: "Marcar captura",
        timerLabel: "Timer",
        timerNone: "Nenhum",
        copyToClipboardToggle: "Copiar para a área de transferência",
        clipboardOnlyChoice: "Somente área de transferência",
        copyToClipboardCaption: "Cada captura e gravação é salva e também vai para a área de transferência como arquivo, pronta para colar em qualquer app.",
        floatingThumbnailToggle: "Mostrar miniatura flutuante",
        floatingThumbnailCaption: "Ao parar, a gravação espera alguns segundos num canto. Clique nela para cortar e editar, arraste para um app ou deixe que ela seja salva sozinha.",
        showClicksToggle: "Mostrar cliques do mouse",
        showClicksCaption: "Uma gravação salva sem o editor marca cada clique com um anel.",
        rememberSelectionToggle: "Lembrar a última seleção",
        showInFinder: "Mostrar no Finder",
        stopHint: "Pare a gravação pela barra de menus ou com ⌃⌘⎋."
    )

    static let tr = CaptureToolbarStrings(
        optionsButton: "Seçenekler",
        captureButton: "Çek",
        recordButton: "Kaydı başlat",
        closeButton: "Kapat",
        captureScreen: "Tüm ekranın resmini çek",
        captureWindow: "Seçili pencerenin resmini çek",
        capturePortion: "Seçili bölümün resmini çek",
        recordScreen: "Tüm ekranı kaydet",
        recordPortion: "Seçili bölümü kaydet",
        markupButton: "Ekran resmine işaretleme yap",
        timerLabel: "Zamanlayıcı",
        timerNone: "Yok",
        copyToClipboardToggle: "Panoya kopyala",
        clipboardOnlyChoice: "Yalnızca pano",
        copyToClipboardCaption: "Her ekran resmi ve kayıt kaydedilir ve dosya olarak panoya da konur, her uygulamaya yapıştırılmaya hazırdır.",
        floatingThumbnailToggle: "Yüzen küçük resmi göster",
        floatingThumbnailCaption: "Durdurduğunuzda kayıt birkaç saniye bir köşede bekler. Budayıp düzenlemek için tıklayın, bir uygulamaya sürükleyin ya da kendiliğinden kaydedilmesine izin verin.",
        showClicksToggle: "Fare tıklamalarını göster",
        showClicksCaption: "Düzenleyici olmadan kaydedilen bir kayıtta her tıklama bir halkayla işaretlenir.",
        rememberSelectionToggle: "Son seçimi hatırla",
        showInFinder: "Finder’da göster",
        stopHint: "Kaydı menü çubuğundan ya da ⌃⌘⎋ ile durdurun."
    )

    static let ru = CaptureToolbarStrings(
        optionsButton: "Параметры",
        captureButton: "Снимок",
        recordButton: "Запись",
        closeButton: "Закрыть",
        captureScreen: "Снимок всего экрана",
        captureWindow: "Снимок выбранного окна",
        capturePortion: "Снимок выбранной области",
        recordScreen: "Запись всего экрана",
        recordPortion: "Запись выбранной области",
        markupButton: "Разметить снимок",
        timerLabel: "Таймер",
        timerNone: "Нет",
        copyToClipboardToggle: "Копировать в буфер обмена",
        clipboardOnlyChoice: "Только буфер обмена",
        copyToClipboardCaption: "Каждый снимок и каждая запись сохраняются и попадают в буфер обмена как файл, готовый для вставки в любое приложение.",
        floatingThumbnailToggle: "Показывать плавающую миниатюру",
        floatingThumbnailCaption: "После остановки запись несколько секунд ждёт в углу. Нажмите на неё, чтобы обрезать и отредактировать, перетащите в приложение или дайте ей сохраниться самой.",
        showClicksToggle: "Показывать нажатия мыши",
        showClicksCaption: "В записи, сохранённой без редактора, каждое нажатие отмечено кольцом.",
        rememberSelectionToggle: "Запоминать последний выбор",
        showInFinder: "Показать в Finder",
        stopHint: "Остановите запись в строке меню или сочетанием ⌃⌘⎋."
    )

    static let es = CaptureToolbarStrings(
        optionsButton: "Opciones",
        captureButton: "Capturar",
        recordButton: "Grabar",
        closeButton: "Cerrar",
        captureScreen: "Capturar toda la pantalla",
        captureWindow: "Capturar la ventana seleccionada",
        capturePortion: "Capturar la parte seleccionada",
        recordScreen: "Grabar toda la pantalla",
        recordPortion: "Grabar la parte seleccionada",
        markupButton: "Anotar captura",
        timerLabel: "Temporizador",
        timerNone: "Ninguno",
        copyToClipboardToggle: "Copiar al portapapeles",
        clipboardOnlyChoice: "Solo portapapeles",
        copyToClipboardCaption: "Cada captura y grabación se guarda y además va al portapapeles como archivo, lista para pegar en cualquier app.",
        floatingThumbnailToggle: "Mostrar miniatura flotante",
        floatingThumbnailCaption: "Al detenerla, la grabación espera unos segundos en una esquina. Haz clic para recortarla y editarla, arrástrala a una app o deja que se guarde sola.",
        showClicksToggle: "Mostrar clics del ratón",
        showClicksCaption: "Una grabación guardada sin el editor marca cada clic con un anillo.",
        rememberSelectionToggle: "Recordar la última selección",
        showInFinder: "Mostrar en Finder",
        stopHint: "Detén la grabación desde la barra de menús o con ⌃⌘⎋."
    )

    static let sk = CaptureToolbarStrings(
        optionsButton: "Možnosti",
        captureButton: "Zachytiť",
        recordButton: "Nahrať",
        closeButton: "Zavrieť",
        captureScreen: "Zachytiť celú obrazovku",
        captureWindow: "Zachytiť vybrané okno",
        capturePortion: "Zachytiť vybranú časť",
        recordScreen: "Nahrať celú obrazovku",
        recordPortion: "Nahrať vybranú časť",
        markupButton: "Označiť snímku",
        timerLabel: "Časovač",
        timerNone: "Žiadny",
        copyToClipboardToggle: "Kopírovať do schránky",
        clipboardOnlyChoice: "Iba schránka",
        copyToClipboardCaption: "Každá snímka a nahrávka sa uloží a zároveň sa vloží do schránky ako súbor, pripravená na vloženie do ľubovoľnej aplikácie.",
        floatingThumbnailToggle: "Zobraziť plávajúcu miniatúru",
        floatingThumbnailCaption: "Po zastavení nahrávka niekoľko sekúnd počká v rohu. Kliknutím ju skrátite a upravíte, môžete ju pretiahnuť do aplikácie alebo ju nechať uložiť samu.",
        showClicksToggle: "Zobraziť kliknutia myši",
        showClicksCaption: "Nahrávka uložená bez editora označí každé kliknutie krúžkom.",
        rememberSelectionToggle: "Pamätať si posledný výber",
        showInFinder: "Zobraziť vo Finderi",
        stopHint: "Nahrávanie zastavíte na lište menu alebo skratkou ⌃⌘⎋."
    )

    static let de = CaptureToolbarStrings(
        optionsButton: "Optionen",
        captureButton: "Aufnehmen",
        recordButton: "Aufzeichnen",
        closeButton: "Schließen",
        captureScreen: "Gesamten Bildschirm aufnehmen",
        captureWindow: "Ausgewähltes Fenster aufnehmen",
        capturePortion: "Ausgewählten Bereich aufnehmen",
        recordScreen: "Gesamten Bildschirm aufzeichnen",
        recordPortion: "Ausgewählten Bereich aufzeichnen",
        markupButton: "Bildschirmfoto markieren",
        timerLabel: "Timer",
        timerNone: "Ohne",
        copyToClipboardToggle: "In die Zwischenablage kopieren",
        clipboardOnlyChoice: "Nur Zwischenablage",
        copyToClipboardCaption: "Jedes Bildschirmfoto und jede Aufnahme wird gesichert und zusätzlich als Datei in die Zwischenablage gelegt, bereit zum Einsetzen in jeder App.",
        floatingThumbnailToggle: "Schwebende Miniatur anzeigen",
        floatingThumbnailCaption: "Nach dem Stoppen wartet die Aufnahme einige Sekunden in einer Ecke. Klicke darauf zum Kürzen und Bearbeiten, ziehe sie in eine App oder lass sie von selbst sichern.",
        showClicksToggle: "Mausklicks anzeigen",
        showClicksCaption: "Eine ohne Editor gesicherte Aufnahme markiert jeden Klick mit einem Ring.",
        rememberSelectionToggle: "Letzte Auswahl merken",
        showInFinder: "Im Finder anzeigen",
        stopHint: "Stoppe eine Aufnahme in der Menüleiste oder mit ⌃⌘⎋."
    )

    static let fr = CaptureToolbarStrings(
        optionsButton: "Options",
        captureButton: "Capturer",
        recordButton: "Enregistrer",
        closeButton: "Fermer",
        captureScreen: "Capturer l’écran entier",
        captureWindow: "Capturer la fenêtre sélectionnée",
        capturePortion: "Capturer la portion sélectionnée",
        recordScreen: "Enregistrer l’écran entier",
        recordPortion: "Enregistrer la portion sélectionnée",
        markupButton: "Annoter la capture",
        timerLabel: "Minuteur",
        timerNone: "Aucun",
        copyToClipboardToggle: "Copier dans le presse-papiers",
        clipboardOnlyChoice: "Presse-papiers uniquement",
        copyToClipboardCaption: "Chaque capture et chaque enregistrement sont sauvegardés et placés aussi dans le presse-papiers sous forme de fichier, prêts à coller dans n’importe quelle app.",
        floatingThumbnailToggle: "Afficher la vignette flottante",
        floatingThumbnailCaption: "Après l’arrêt, l’enregistrement attend quelques secondes dans un coin. Cliquez dessus pour le rogner et le modifier, faites-le glisser dans une app ou laissez-le s’enregistrer tout seul.",
        showClicksToggle: "Afficher les clics de la souris",
        showClicksCaption: "Un enregistrement sauvegardé sans l’éditeur marque chaque clic d’un anneau.",
        rememberSelectionToggle: "Mémoriser la dernière sélection",
        showInFinder: "Afficher dans le Finder",
        stopHint: "Arrêtez l’enregistrement depuis la barre des menus ou avec ⌃⌘⎋."
    )

    static let it = CaptureToolbarStrings(
        optionsButton: "Opzioni",
        captureButton: "Cattura",
        recordButton: "Registra",
        closeButton: "Chiudi",
        captureScreen: "Cattura schermo intero",
        captureWindow: "Cattura finestra selezionata",
        capturePortion: "Cattura porzione selezionata",
        recordScreen: "Registra schermo intero",
        recordPortion: "Registra porzione selezionata",
        markupButton: "Annota istantanea",
        timerLabel: "Timer",
        timerNone: "Nessuno",
        copyToClipboardToggle: "Copia negli appunti",
        clipboardOnlyChoice: "Solo appunti",
        copyToClipboardCaption: "Ogni istantanea e registrazione viene salvata e messa anche negli appunti come file, pronta da incollare in qualsiasi app.",
        floatingThumbnailToggle: "Mostra miniatura mobile",
        floatingThumbnailCaption: "Dopo l’arresto, la registrazione aspetta qualche secondo in un angolo. Fai clic per tagliarla e modificarla, trascinala in un’app o lasciala salvare da sola.",
        showClicksToggle: "Mostra i clic del mouse",
        showClicksCaption: "Una registrazione salvata senza l’editor segna ogni clic con un anello.",
        rememberSelectionToggle: "Ricorda l’ultima selezione",
        showInFinder: "Mostra nel Finder",
        stopHint: "Interrompi la registrazione dalla barra dei menu o con ⌃⌘⎋."
    )

    static let ja = CaptureToolbarStrings(
        optionsButton: "オプション",
        captureButton: "取り込む",
        recordButton: "収録",
        closeButton: "閉じる",
        captureScreen: "画面全体を取り込む",
        captureWindow: "選択したウインドウを取り込む",
        capturePortion: "選択部分を取り込む",
        recordScreen: "画面全体を収録",
        recordPortion: "選択部分を収録",
        markupButton: "スクリーンショットにマークアップ",
        timerLabel: "タイマー",
        timerNone: "なし",
        copyToClipboardToggle: "クリップボードにコピー",
        clipboardOnlyChoice: "クリップボードのみ",
        copyToClipboardCaption: "スクリーンショットと収録はすべて保存され、ファイルとしてクリップボードにも入るので、どのアプリにもそのままペーストできます。",
        floatingThumbnailToggle: "フローティングサムネールを表示",
        floatingThumbnailCaption: "停止すると、収録は数秒間画面の隅で待機します。クリックするとトリムと編集ができ、アプリにドラッグすることも、そのまま自動で保存させることもできます。",
        showClicksToggle: "マウスのクリックを表示",
        showClicksCaption: "エディタを使わずに保存した収録では、クリックごとにリングが表示されます。",
        rememberSelectionToggle: "最後の選択部分を記憶",
        showInFinder: "Finderに表示",
        stopHint: "メニューバーまたは⌃⌘⎋で収録を停止できます。"
    )

    static let ko = CaptureToolbarStrings(
        optionsButton: "옵션",
        captureButton: "캡처",
        recordButton: "기록",
        closeButton: "닫기",
        captureScreen: "전체 화면 캡처",
        captureWindow: "선택한 윈도우 캡처",
        capturePortion: "선택 부분 캡처",
        recordScreen: "전체 화면 기록",
        recordPortion: "선택 부분 기록",
        markupButton: "스크린샷 마크업",
        timerLabel: "타이머",
        timerNone: "없음",
        copyToClipboardToggle: "클립보드에 복사",
        clipboardOnlyChoice: "클립보드만",
        copyToClipboardCaption: "모든 스크린샷과 화면 기록은 저장되고 파일로 클립보드에도 복사되어, 어떤 앱에든 바로 붙여넣을 수 있습니다.",
        floatingThumbnailToggle: "플로팅 썸네일 보기",
        floatingThumbnailCaption: "중지하면 화면 기록이 몇 초 동안 모서리에서 기다립니다. 클릭하여 다듬고 편집하거나, 앱으로 드래그하거나, 자동으로 저장되게 둘 수 있습니다.",
        showClicksToggle: "마우스 클릭 보기",
        showClicksCaption: "편집기 없이 저장한 화면 기록에는 클릭마다 링이 표시됩니다.",
        rememberSelectionToggle: "마지막 선택 영역 기억",
        showInFinder: "Finder에서 보기",
        stopHint: "메뉴 막대나 ⌃⌘⎋로 화면 기록을 중지할 수 있습니다."
    )

    static let zhHans = CaptureToolbarStrings(
        optionsButton: "选项",
        captureButton: "捕捉",
        recordButton: "录制",
        closeButton: "关闭",
        captureScreen: "捕捉整个屏幕",
        captureWindow: "捕捉所选窗口",
        capturePortion: "捕捉所选部分",
        recordScreen: "录制整个屏幕",
        recordPortion: "录制所选部分",
        markupButton: "标记截屏",
        timerLabel: "定时器",
        timerNone: "无",
        copyToClipboardToggle: "拷贝到剪贴板",
        clipboardOnlyChoice: "仅剪贴板",
        copyToClipboardCaption: "每张截屏和每段录制都会存储，并以文件形式放到剪贴板，可直接粘贴到任何 App。",
        floatingThumbnailToggle: "显示浮动缩略图",
        floatingThumbnailCaption: "停止后，录制内容会在角落停留几秒。点按它可以修剪和编辑，也可以拖到 App 中，或让它自动存储。",
        showClicksToggle: "显示鼠标点按",
        showClicksCaption: "不经过编辑器存储的录制内容会用圆环标出每次点按。",
        rememberSelectionToggle: "记住上次选择",
        showInFinder: "在访达中显示",
        stopHint: "可以从菜单栏或按 ⌃⌘⎋ 停止录制。"
    )

    static let zhTW = CaptureToolbarStrings(
        optionsButton: "選項",
        captureButton: "擷取",
        recordButton: "錄製",
        closeButton: "關閉",
        captureScreen: "擷取整個螢幕",
        captureWindow: "擷取所選視窗",
        capturePortion: "擷取所選部分",
        recordScreen: "錄製整個螢幕",
        recordPortion: "錄製所選部分",
        markupButton: "標示截圖",
        timerLabel: "計時器",
        timerNone: "無",
        copyToClipboardToggle: "拷貝到剪貼板",
        clipboardOnlyChoice: "僅剪貼板",
        copyToClipboardCaption: "每張截圖和每段錄影都會儲存，並以檔案形式放到剪貼板，可直接貼到任何 App。",
        floatingThumbnailToggle: "顯示浮動縮覽圖",
        floatingThumbnailCaption: "停止後，錄影會在角落停留幾秒。按一下即可修剪和編輯，也可以拖到 App 中，或讓它自動儲存。",
        showClicksToggle: "顯示滑鼠點按",
        showClicksCaption: "未經編輯器儲存的錄影會用圓環標示每次點按。",
        rememberSelectionToggle: "記住上次的選擇範圍",
        showInFinder: "在 Finder 中顯示",
        stopHint: "可從選單列或按 ⌃⌘⎋ 停止錄影。"
    )

    static let zhHK = CaptureToolbarStrings(
        optionsButton: "選項",
        captureButton: "擷取",
        recordButton: "錄製",
        closeButton: "關閉",
        captureScreen: "擷取整個螢幕",
        captureWindow: "擷取所選視窗",
        capturePortion: "擷取所選部分",
        recordScreen: "錄製整個螢幕",
        recordPortion: "錄製所選部分",
        markupButton: "標示截圖",
        timerLabel: "計時器",
        timerNone: "無",
        copyToClipboardToggle: "拷貝到剪貼板",
        clipboardOnlyChoice: "僅剪貼板",
        copyToClipboardCaption: "每張截圖和每段錄影都會儲存，並以檔案形式放到剪貼板，可直接貼到任何 App。",
        floatingThumbnailToggle: "顯示浮動縮圖",
        floatingThumbnailCaption: "停止後，錄影會在角落停留幾秒。按一下即可修剪和編輯，亦可拖到 App 中，或讓它自動儲存。",
        showClicksToggle: "顯示滑鼠點按",
        showClicksCaption: "未經編輯器儲存的錄影會以圓環標示每次點按。",
        rememberSelectionToggle: "記住上次的選擇範圍",
        showInFinder: "在 Finder 中顯示",
        stopHint: "可從選單列或按 ⌃⌘⎋ 停止錄影。"
    )

    static let uk = CaptureToolbarStrings(
        optionsButton: "Параметри",
        captureButton: "Знімок",
        recordButton: "Запис",
        closeButton: "Закрити",
        captureScreen: "Знімок усього екрана",
        captureWindow: "Знімок вибраного вікна",
        capturePortion: "Знімок вибраної області",
        recordScreen: "Запис усього екрана",
        recordPortion: "Запис вибраної області",
        markupButton: "Розмітити знімок",
        timerLabel: "Таймер",
        timerNone: "Немає",
        copyToClipboardToggle: "Копіювати в буфер обміну",
        clipboardOnlyChoice: "Лише буфер обміну",
        copyToClipboardCaption: "Кожен знімок і кожен запис зберігаються та потрапляють у буфер обміну як файл, готовий до вставлення в будь-який застосунок.",
        floatingThumbnailToggle: "Показувати плаваючу мініатюру",
        floatingThumbnailCaption: "Після зупинки запис кілька секунд чекає в куті. Натисніть на нього, щоб обрізати й відредагувати, перетягніть у застосунок або дайте йому зберегтися самому.",
        showClicksToggle: "Показувати натискання миші",
        showClicksCaption: "Запис, збережений без редактора, позначає кожне натискання кільцем.",
        rememberSelectionToggle: "Запам’ятовувати останній вибір",
        showInFinder: "Показати у Finder",
        stopHint: "Зупиніть запис у рядку меню або сполученням ⌃⌘⎋."
    )
}
