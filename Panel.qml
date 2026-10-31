import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Lightning wallet: a bolt in the bar and a popup under it.
//
// Every wallet operation goes through bin/omarchy-lightning, which prints one
// JSON object per call. The seed and the Lexe SDK stay in that process, never
// in the shell.
Panel {
  id: root
  moduleName: "omarchy-lightning"

  // "loading" | "uninitialized" | "ready" | "error"
  property string walletState: "loading"
  property real balanceSats: 0
  property string notice: ""
  property bool noticeIsError: false
  property bool busy: false
  property bool setupFailed: false

  // "home" | "receive" | "send"
  property string view: "home"
  property string invoice: ""
  property var qrRows: []
  property string invoiceIndex: ""
  property string sendIndex: ""
  property bool received: false
  property string payable: ""

  readonly property string cli: Qt.resolvedUrl("bin/omarchy-lightning").toString().replace(/^file:\/\//, "")
  readonly property bool funded: balanceSats > 0
  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property string family: root.bar ? root.bar.fontFamily : Style.font.family

  function fmt(sats) {
    return Commons.I18n.formatNumber(Math.round(sats))
  }

  // Amounts are whole sats, the base unit, written with the bitcoin sign: ₿80.
  function btc(sats) {
    return "\u20bf" + fmt(sats)
  }

  function say(text, isError) {
    notice = text
    noticeIsError = !!isError
  }

  // Runs the backend and hands the parsed JSON to `done`. A script that dies
  // without JSON is reported with whatever it wrote to stderr.
  function call(proc, args, done) {
    if (proc.running) return
    proc.done = done
    proc.command = [root.cli].concat(args)
    proc.running = true
  }

  function refresh() {
    call(statusProc, ["status"], function(r) {
      if (r.error) { walletState = "error"; say(r.error, true); return }
      walletState = r.state
      if (r.state === "ready") balanceSats = r.balance_sats
      // First use: opening the popup creates the wallet. Closed-popup
      // refreshes never do, so installing the plugin alone creates nothing,
      // and a failed attempt waits for the button instead of retrying.
      else if (r.state === "uninitialized" && opened && !busy && !setupFailed) createWallet()
    })
  }

  function createWallet() {
    busy = true
    setupFailed = false
    say(I18n.t("lightning.creating", "Creating your wallet…"), false)
    call(setupProc, ["setup"], function(r) {
      busy = false
      if (r.error) { setupFailed = true; say(r.error, true); return }
      say("", false)
      refresh()
    })
  }

  function makeInvoice(amount) {
    busy = true
    var args = ["invoice", "--description", "Omarchy Lightning"]
    if (amount > 0) args = args.concat(["--amount", String(amount)])
    call(invoiceProc, args, function(r) {
      busy = false
      if (r.error) { say(r.error, true); return }
      invoice = r.invoice
      qrRows = r.qr || []
      invoiceIndex = r.index
      received = false
      say("", false)
    })
  }

  function copyInvoice() {
    Quickshell.execDetached(["wl-copy", invoice])
    say(I18n.t("lightning.copied", "Invoice copied"), false)
  }

  function sendPayment(destination, amount) {
    payable = destination.trim()
    busy = true
    say("", false)
    var args = ["pay", payable]
    if (amount > 0) args = args.concat(["--amount", String(amount)])
    call(payProc, args, function(r) {
      busy = false
      if (r.error) { say(r.error, true); return }
      if (r.status === "completed") finishSend()
      else if (r.status === "failed") say(r.message || I18n.t("lightning.failed", "Payment failed"), true)
      else { sendIndex = r.index; busy = true; say(I18n.t("lightning.confirming", "Waiting for confirmation…"), false) }
    })
  }

  function finishSend() {
    sendIndex = ""
    busy = false
    say(I18n.t("lightning.sent", "Payment sent"), false)
    view = "home"
    payable = ""
    refresh()
  }

  // Polled while an invoice is on screen or a send is pending.
  function pollPayment() {
    var index = view === "send" ? sendIndex : invoiceIndex
    if (index === "" || pollProc.running) return
    call(pollProc, ["payment", index], function(r) {
      if (r.error || r.status === "pending") return
      if (view === "send") {
        if (r.status === "completed") finishSend()
        else { sendIndex = ""; busy = false; say(r.message || I18n.t("lightning.failed", "Payment failed"), true) }
      } else if (r.status === "completed") {
        received = true
        invoiceIndex = ""
        say(I18n.t("lightning.received", "Payment received"), false)
        refresh()
      }
    })
  }

  function goHome() {
    view = "home"
    invoice = ""
    qrRows = []
    invoiceIndex = ""
    received = false
    payable = ""
    say("", false)
  }

  onOpenedChanged: {
    if (opened) { goHome(); refresh() }
  }

  Component.onCompleted: refresh()
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.refresh() }
  Timer {
    interval: 3000
    running: root.opened && ((root.view === "receive" && root.invoiceIndex !== "") || (root.view === "send" && root.sendIndex !== ""))
    repeat: true
    onTriggered: root.pollPayment()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  component Backend: Process {
    id: proc
    property var done: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed
        try { parsed = JSON.parse(String(text).trim().split("\n").pop()) }
        catch (e) { parsed = { error: I18n.t("lightning.noResponse", "The wallet backend did not respond.") } }
        if (proc.done) proc.done(parsed)
      }
    }
  }

  Backend { id: statusProc }
  Backend { id: setupProc }
  Backend { id: invoiceProc }
  Backend { id: payProc }
  Backend { id: pollProc }

  TextMetrics {
    id: balanceMetrics
    font.family: root.family
    font.pixelSize: Style.bar.iconFont
    text: root.btc(root.balanceSats)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    // The balance sits left of the bolt, so the slot grows to hold it. A
    // vertical bar has no room for text and keeps just the bolt.
    // Before the wallet exists the balance is zero. "loading" shows no
    // number, so a funded wallet never flashes ₿0 while the first check runs.
    labelText: (root.walletState === "ready" || root.walletState === "uninitialized") && !vertical ? root.btc(root.balanceSats) : ""
    slotSize: Style.bar.iconSlot + (labelText !== "" ? balanceMetrics.advanceWidth + Style.space(8) : 0)
    tooltipText: root.walletState === "ready" || root.walletState === "uninitialized" ? root.btc(root.balanceSats) : ""
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      blocked: amountField.activeFocus || payableField.activeFocus || sendAmountField.activeFocus
      onCloseRequested: root.view === "home" ? root.close() : root.goHome()

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: balance ----------
        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            textFormat: Text.PlainText
            text: ""
            color: root.fg
            font.family: root.family
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: I18n.t("lightning.title", "Lightning")
              color: root.fg
              font.family: root.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.walletState === "ready" ? root.btc(root.balanceSats)
                : root.walletState === "uninitialized" ? (root.setupFailed ? I18n.t("lightning.noWallet", "No wallet yet") : I18n.t("lightning.settingUp", "Setting up…"))
                : root.walletState === "loading" ? I18n.t("lightning.loading", "Loading…")
                : I18n.t("lightning.unavailable", "Unavailable")
              color: root.fg
              font.family: root.family
              font.pixelSize: root.walletState === "ready" ? Style.font.displayLarge : Style.font.bodySmall
              font.bold: root.walletState === "ready"
              opacity: root.walletState === "ready" ? 1 : 0.6
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---------- No wallet yet ----------
        Column {
          visible: root.walletState === "uninitialized" && root.setupFailed
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: I18n.t("lightning.createFailed", "Your wallet could not be created. Check your connection and try again.")
            color: root.fg
            opacity: 0.7
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            width: parent.width
            text: I18n.t("lightning.retryCreate", "Try again")
            foreground: root.fg
            fontFamily: root.family
            bordered: true
            enabled: !root.busy
            onClicked: root.createWallet()
          }
        }

        // ---------- Home: fund when empty, send when funded ----------
        Column {
          visible: root.walletState === "ready" && root.view === "home"
          width: parent.width
          spacing: Style.space(10)

          Text {
            visible: !root.funded
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: I18n.t("lightning.fundPrompt", "Your wallet is empty. Fund it by paying a Lightning invoice.")
            color: root.fg
            opacity: 0.7
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            visible: root.funded
            width: parent.width
            text: I18n.t("lightning.send", "Send")
            foreground: root.fg
            fontFamily: root.family
            bordered: true
            onClicked: root.view = "send"
          }
          Button {
            width: parent.width
            text: root.funded ? I18n.t("lightning.receive", "Receive") : I18n.t("lightning.fund", "Fund wallet")
            foreground: root.fg
            fontFamily: root.family
            bordered: true
            onClicked: { root.view = "receive"; amountField.text = "" }
          }
        }

        // ---------- Receive / fund ----------
        Column {
          visible: root.walletState === "ready" && root.view === "receive"
          width: parent.width
          spacing: Style.space(10)

          TextField {
            id: amountField
            width: parent.width
            visible: root.invoice === ""
            placeholderText: I18n.t("lightning.amountOptional", "Amount in \u20bf (optional)")
            foreground: root.fg
            inputMethodHints: Qt.ImhDigitsOnly
            validator: IntValidator { bottom: 1 }
            onAccepted: root.makeInvoice(parseInt(text || "0"))
          }
          Button {
            visible: root.invoice === ""
            width: parent.width
            text: I18n.t("lightning.makeInvoice", "Create invoice")
            foreground: root.fg
            fontFamily: root.family
            bordered: true
            enabled: !root.busy
            onClicked: root.makeInvoice(parseInt(amountField.text || "0"))
          }
          // One native rectangle per dark module, as the Wi-Fi share card does.
          // White canvas so the code scans on any theme.
          Rectangle {
            id: qrCanvas
            readonly property int size: root.qrRows.length
            readonly property int moduleSize: size > 0 ? Math.max(3, Math.floor(Style.space(220) / size)) : 0
            visible: root.invoice !== "" && size > 0 && !root.received
            width: size * moduleSize
            height: width
            color: "white"
            radius: Style.cornerRadius
            anchors.horizontalCenter: parent.horizontalCenter

            Grid {
              anchors.fill: parent
              columns: qrCanvas.size
              // A mirrored QR code does not scan.
              LayoutMirroring.enabled: false
              Repeater {
                model: qrCanvas.size * qrCanvas.size
                Rectangle {
                  required property int index
                  width: qrCanvas.moduleSize
                  height: qrCanvas.moduleSize
                  color: root.qrRows[Math.floor(index / qrCanvas.size)].charAt(index % qrCanvas.size) === "1" ? "#111111" : "transparent"
                }
              }
            }
          }
          Text {
            visible: root.invoice !== "" && !root.received
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: I18n.t("lightning.waiting", "Waiting for payment…")
            color: root.fg
            opacity: 0.6
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            visible: root.invoice !== "" && !root.received
            width: parent.width
            text: I18n.t("lightning.copyInvoice", "Copy invoice")
            foreground: root.fg
            fontFamily: root.family
            bordered: true
            onClicked: root.copyInvoice()
          }
          Button {
            width: parent.width
            text: I18n.t("lightning.back", "Back")
            foreground: root.fg
            fontFamily: root.family
            onClicked: root.goHome()
          }
        }

        // ---------- Send ----------
        Column {
          visible: root.walletState === "ready" && root.view === "send"
          width: parent.width
          spacing: Style.space(10)

          TextField {
            id: payableField
            width: parent.width
            placeholderText: I18n.t("lightning.payablePlaceholder", "Invoice, offer, address or Lightning address")
            foreground: root.fg
            onTextEdited: root.say("", false)
            onAccepted: sendAmountField.forceActiveFocus()
          }
          // Left empty for an invoice that already carries an amount; the
          // backend ignores it there, so one screen covers every kind of payable.
          TextField {
            id: sendAmountField
            width: parent.width
            placeholderText: I18n.t("lightning.amountSats", "Amount in \u20bf")
            foreground: root.fg
            inputMethodHints: Qt.ImhDigitsOnly
            validator: IntValidator { bottom: 1 }
            onAccepted: sendButton.clicked()
          }
          Button {
            id: sendButton
            width: parent.width
            text: I18n.t("lightning.send", "Send")
            foreground: root.fg
            fontFamily: root.family
            bordered: true
            enabled: !root.busy && payableField.text.trim() !== ""
            onClicked: if (enabled) root.sendPayment(payableField.text, parseInt(sendAmountField.text || "0"))
          }
          Button {
            width: parent.width
            text: I18n.t("lightning.back", "Back")
            foreground: root.fg
            fontFamily: root.family
            onClicked: { payableField.text = ""; sendAmountField.text = ""; root.goHome() }
          }
        }

        // ---------- Status line ----------
        Text {
          visible: root.notice !== "" || root.busy
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: root.busy && root.notice === "" ? I18n.t("lightning.working", "Working…") : root.notice
          color: root.noticeIsError && root.bar ? root.bar.urgent : root.fg
          opacity: root.noticeIsError ? 1 : 0.7
          font.family: root.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}
