import SwiftUI

extension Binding where Value == Bool {
    /// 옵셔널 상태로 시트/패널 표시 여부를 만들 때 사용.
    /// `.constant(x != nil)`은 dismiss()가 false를 쓸 곳이 없어 시트가 영원히 닫히지 않는다 —
    /// 이 바인딩은 닫힐 때 원본 상태를 nil로 되돌린다.
    init<T>(presence source: Binding<T?>) {
        self.init(get: { source.wrappedValue != nil },
                  set: { if !$0 { source.wrappedValue = nil } })
    }
}
