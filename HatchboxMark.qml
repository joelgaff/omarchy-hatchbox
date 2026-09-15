import QtQuick
import QtQuick.Shapes
import qs.Commons

// The Hatchbox "H", drawn rather than typed: three rounded drips joined by
// two short bridges. The original mark is an orange gradient; in the bar it
// takes the theme foreground, and the urgent color when a deploy has failed,
// so it reads like every other icon there.
//
// Traced on a 24x24 grid and scaled to whatever size the bar hands over.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  implicitWidth: iconSize
  implicitHeight: iconSize

  Item {
    anchors.centerIn: parent
    width: 24
    height: 24
    scale: root.iconSize / 24

    Shape {
      anchors.fill: parent
      antialiasing: true
      layer.enabled: true
      layer.samples: 4
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeColor: root.color
        strokeWidth: 4.4
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin

        // Left drip
        startX: 5.0; startY: 7.4
        PathLine { x: 5.0; y: 15.2 }
        // Middle drip
        PathMove { x: 12.0; y: 8.4 }
        PathLine { x: 12.0; y: 19.4 }
        // Right drip
        PathMove { x: 19.0; y: 5.0 }
        PathLine { x: 19.0; y: 17.2 }
        // Bridges
        PathMove { x: 5.0; y: 11.2 }
        PathLine { x: 12.0; y: 11.2 }
        PathMove { x: 12.0; y: 15.4 }
        PathLine { x: 19.0; y: 15.4 }
      }
    }
  }
}
