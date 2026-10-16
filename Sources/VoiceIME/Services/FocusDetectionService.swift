import Foundation
import ApplicationServices
import AppKit

public enum AccessibilityFocusState: CustomStringConvertible, Equatable {
    case editableText(role: String, detail: String)
    case notEditable(role: String, detail: String)
    case ambiguous(role: String, detail: String)

    public var description: String {
        switch self {
        case .editableText(let role, let detail):
            return "確実に入力可能 (\(role): \(detail))"
        case .notEditable(let role, let detail):
            return "入力不可 (\(role): \(detail))"
        case .ambiguous(let role, let detail):
            return "判定微妙/Web系 (\(role): \(detail))"
        }
    }

    public var isDefinitelyEditable: Bool {
        if case .editableText = self { return true }
        return false
    }

    public var isDefinitelyNotEditable: Bool {
        if case .notEditable = self { return true }
        return false
    }
}

public final class FocusDetectionService {
    public static let shared = FocusDetectionService()

    private init() {}

    /// 現在のシステム全体のフォーカス要素を解析し、テキスト入力が可能かどうかを判定
    public func checkCurrentFocus() -> AccessibilityFocusState {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )

        guard result == .success, let element = focusedElementRef else {
            return .ambiguous(role: "None", detail: "フォーカス要素取得不能")
        }

        // CFTypeRef を AXUIElement としてキャスト
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return .ambiguous(role: "UnknownType", detail: "UIElement型不一致")
        }
        let axElement = element as! AXUIElement

        // 1. 要素の Role（役割）を取得
        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleResult == .success ? roleRef as? String : nil) ?? "UnknownRole"

        // 2. 要素の Subrole を取得
        var subroleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? ""

        // 3. 確実に入力可能な標準 Role
        let editableRoles: Set<String> = [
            "AXTextField",
            "AXTextArea",
            "AXComboBox",
            "AXSearchField"
        ]

        if editableRoles.contains(role) {
            return .editableText(role: role, detail: subrole.isEmpty ? "標準テキスト欄" : subrole)
        }

        // 4. contenteditable 属性を持つリッチエディタ要素
        if subrole == "AXContentEditable" {
            return .editableText(role: role, detail: "コンテンツ編集可能領域 (contenteditable)")
        }

        // 5. 明らかに入力不可能な Role (ブラウザのWebページ全体 AXWebArea を含む)
        let nonEditableRoles: Set<String> = [
            "AXWebArea",      // ブラウザのWebページ全体（ページ内のテキスト入力欄が未選択の状態）
            "AXStaticText",   // 静的テキストラベル
            "AXButton",
            "AXRadioButton",
            "AXCheckBox",
            "AXPopUpButton",
            "AXMenuButton",
            "AXImage",
            "AXSlider",
            "AXColorWell",
            "AXMenu",
            "AXMenuBar",
            "AXMenuBarItem",
            "AXMenuItem",
            "AXScrollBar",
            "AXSplitter",
            "AXDesktop",
            "AXDockItem",
            "AXWindow",
            "AXApplication"
        ]

        if nonEditableRoles.contains(role) {
            let detail = (role == "AXWebArea") ? "ブラウザWebページ全体 (入力欄未選択)" : (subrole.isEmpty ? "非テキストUI要素" : subrole)
            return .notEditable(role: role, detail: detail)
        }

        // 6. テキスト値の変更可能性 (kAXValueAttribute が変更可能かどうか)
        var isSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &isSettable) == .success, isSettable.boolValue {
            // テキスト値が書き換え可能なUI要素
            return .editableText(role: role, detail: "値書き換え可能属性あり")
        }

        // 7. キャレット（入力カーソル）または編集可能祖先 (AXEditableAncestor) の検査
        var editableAncestorRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, "AXEditableAncestor" as CFString, &editableAncestorRef) == .success, editableAncestorRef != nil {
            return .editableText(role: role, detail: "編集可能祖先(Web/エディタ)")
        }

        // 8. それ以外 (AXGroup, AXScrollArea 等) は Electron や Web アプリの可能性があるため "ambiguous"
        return .ambiguous(role: role, detail: subrole.isEmpty ? "独自描画・Web領域" : subrole)
    }
}
