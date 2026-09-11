from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_LEFT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    KeepTogether,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output" / "pdf"
PUBLIC = ROOT / "public" / "documents"
NAVY = colors.HexColor("#071D33")
ORANGE = colors.HexColor("#FF650A")
INK = colors.HexColor("#183044")
MUTED = colors.HexColor("#637587")
LINE = colors.HexColor("#DDE5EC")
PALE = colors.HexColor("#F5F8FB")


def page(canvas, doc):
    canvas.saveState()
    width, height = letter
    canvas.setFillColor(NAVY)
    canvas.rect(0, height - 24 * mm, width, 24 * mm, fill=1, stroke=0)
    canvas.setFillColor(ORANGE)
    canvas.circle(22 * mm, height - 12 * mm, 5.5 * mm, fill=1, stroke=0)
    canvas.setFillColor(colors.white)
    canvas.setFont("Helvetica-Bold", 18)
    canvas.drawString(32 * mm, height - 15 * mm, "Yavoi!")
    canvas.setFont("Helvetica", 7.5)
    canvas.drawRightString(width - 18 * mm, height - 13 * mm, "EXPEDIENTE DE CONDUCTOR")
    canvas.setStrokeColor(ORANGE)
    canvas.setLineWidth(1.4)
    canvas.line(18 * mm, 16 * mm, 53 * mm, 16 * mm)
    canvas.setFillColor(MUTED)
    canvas.setFont("Helvetica", 7.5)
    canvas.drawString(18 * mm, 10.5 * mm, "Yavoi! · Tu raite, al instante · Delicias, Chihuahua")
    canvas.drawRightString(width - 18 * mm, 10.5 * mm, f"Página {doc.page}")
    canvas.restoreState()


STYLES = getSampleStyleSheet()
TITLE = ParagraphStyle(
    "TitleYavoi",
    parent=STYLES["Title"],
    fontName="Helvetica-Bold",
    fontSize=18,
    leading=22,
    textColor=NAVY,
    alignment=TA_LEFT,
    spaceAfter=5 * mm,
)
SUBTITLE = ParagraphStyle(
    "SubtitleYavoi",
    parent=STYLES["Heading2"],
    fontName="Helvetica-Bold",
    fontSize=10.5,
    leading=14,
    textColor=ORANGE,
    spaceBefore=4 * mm,
    spaceAfter=2 * mm,
)
BODY = ParagraphStyle(
    "BodyYavoi",
    parent=STYLES["BodyText"],
    fontName="Helvetica",
    fontSize=9,
    leading=13.2,
    textColor=INK,
    alignment=TA_JUSTIFY,
    spaceAfter=2.4 * mm,
)
SMALL = ParagraphStyle(
    "SmallYavoi",
    parent=BODY,
    fontSize=7.6,
    leading=10,
    textColor=MUTED,
)
ITEM = ParagraphStyle(
    "ItemYavoi",
    parent=BODY,
    leftIndent=5 * mm,
    firstLineIndent=-4 * mm,
    bulletIndent=0,
    spaceAfter=1.6 * mm,
)
CENTER = ParagraphStyle(
    "CenterYavoi",
    parent=BODY,
    alignment=TA_CENTER,
)


def document(path, title, intro, sections, reference=None):
    doc = BaseDocTemplate(
        str(path),
        pagesize=letter,
        leftMargin=18 * mm,
        rightMargin=18 * mm,
        topMargin=31 * mm,
        bottomMargin=22 * mm,
        title=title,
        author="Yavoi!",
        subject="Expediente de conductor",
    )
    frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="body")
    doc.addPageTemplates(PageTemplate(id="yavoi", frames=frame, onPage=page))
    story = [Paragraph(title, TITLE), Paragraph(intro, BODY)]
    if reference:
        note = Table(
            [[Paragraph("REFERENCIA NORMATIVA", SMALL), Paragraph(reference, SMALL)]],
            colWidths=[39 * mm, doc.width - 39 * mm],
        )
        note.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, -1), PALE),
                    ("BOX", (0, 0), (-1, -1), 0.6, LINE),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 7),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 7),
                    ("TOPPADDING", (0, 0), (-1, -1), 7),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
                ]
            )
        )
        story += [note, Spacer(1, 2 * mm)]
    for heading, items in sections:
        story.append(Paragraph(heading, SUBTITLE))
        for number, text in enumerate(items, 1):
            story.append(Paragraph(f"{number}. {text}", ITEM))
    declaration = [
        [Paragraph("Nombre completo", SMALL), ""],
        [Paragraph("CURP", SMALL), ""],
        [Paragraph("Número de licencia", SMALL), ""],
        [Paragraph("Lugar y fecha", SMALL), ""],
        [Paragraph("Firma autógrafa", SMALL), ""],
    ]
    form = Table(declaration, colWidths=[43 * mm, doc.width - 43 * mm], rowHeights=[12 * mm] * 5)
    form.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (0, -1), PALE),
                ("BOX", (0, 0), (-1, -1), 0.6, LINE),
                ("INNERGRID", (0, 0), (-1, -1), 0.4, LINE),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("LEFTPADDING", (0, 0), (-1, -1), 7),
                ("RIGHTPADDING", (0, 0), (-1, -1), 7),
            ]
        )
    )
    story += [Spacer(1, 3 * mm), KeepTogether([Paragraph("Declaración y firma", SUBTITLE), form])]
    story += [
        Spacer(1, 3 * mm),
        Paragraph(
            "Declaro que leí y comprendí este documento, que la información proporcionada es verdadera y que firmo libremente. Conservaré una copia y cargaré en Yavoi! el documento completo y legible.",
            SMALL,
        ),
    ]
    doc.build(story)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    PUBLIC.mkdir(parents=True, exist_ok=True)
    policy_path = OUTPUT / "carta-compromiso-politicas-yavoi.pdf"
    traffic_path = OUTPUT / "carta-aceptacion-vialidad-chihuahua.pdf"
    document(
        policy_path,
        "Carta de compromiso y aceptación de políticas Yavoi!",
        "A quien corresponda: Por medio de la presente, la persona conductora que firma solicita integrar su expediente en Yavoi! y asume los siguientes compromisos como condición para conservar su autorización dentro de la plataforma.",
        [
            (
                "Servicio, seguridad y trato",
                [
                    "Prestaré cada servicio con respeto, puntualidad, conducción preventiva y trato digno, sin discriminación, hostigamiento, violencia ni represalias.",
                    "Confirmaré que la unidad, placas y conductor coincidan con los datos autorizados. No prestaré, compartiré ni transferiré mi cuenta o credenciales.",
                    "Respetaré la capacidad de pasajeros y carga de mi categoría; rechazaré de forma segura cualquier solicitud que exceda la capacidad o comprometa la seguridad.",
                    "Mantendré licencia, tarjeta de circulación, seguro y permisos aplicables vigentes, así como la unidad en condiciones mecánicas, eléctricas, sanitarias y de seguridad adecuadas.",
                    "No conduciré bajo efectos de alcohol, drogas, medicamentos incapacitantes, fatiga peligrosa o cualquier condición que reduzca mi capacidad de conducción.",
                ],
            ),
            (
                "Uso de la plataforma y datos",
                [
                    "Mantendré activada mi disponibilidad únicamente cuando pueda aceptar y realizar servicios. Atenderé las solicitudes sin manipular ubicación, tiempos, recorridos, tarifas o estados del viaje.",
                    "Autorizo el tratamiento de mi ubicación durante disponibilidad y viajes para asignación, seguridad, soporte, conciliación y auditoría, conforme al aviso de privacidad aplicable.",
                    "Protegeré los datos del pasajero y no los usaré fuera del servicio, salvo una emergencia o requerimiento legítimo de autoridad.",
                    "Registraré correctamente pagos en efectivo, propinas e incidentes. No solicitaré importes distintos a los mostrados por la plataforma, salvo ajustes autorizados y documentados.",
                    "Reportaré de inmediato accidentes, amenazas, fallas, objetos olvidados, posibles fraudes y cualquier situación de riesgo; cooperaré con Operaciones y con la autoridad competente.",
                ],
            ),
            (
                "Expediente y continuidad",
                [
                    "La documentación que entrego es auténtica, vigente y corresponde a mi persona y unidad. Informaré cualquier cambio y aceptaré una nueva revisión.",
                    "Cumpliré las cuotas de uso, políticas vigentes, medidas de seguridad y revisiones comunicadas por Yavoi!, sin perjuicio de mis derechos legales.",
                    "Comprendo que la cuenta puede permanecer pendiente, desactivarse o suspenderse ante documentación incompleta o vencida, riesgos de seguridad o incumplimientos, con registro de la decisión y canales de aclaración.",
                    "Esta carta no sustituye contratos, avisos de privacidad, permisos, licencias, seguros ni obligaciones legales aplicables.",
                ],
            ),
        ],
    )
    document(
        traffic_path,
        "Carta de compromiso y aceptación de obligaciones viales",
        "A quien corresponda: Declaro conocer que toda persona que utiliza las vías públicas en el Estado de Chihuahua debe cumplir la Ley de Vialidad y Tránsito, sus reglamentos y las disposiciones municipales y federales que correspondan a la actividad y al tipo de servicio.",
        [
            (
                "Obligaciones que acepto",
                [
                    "Usaré el cinturón de seguridad y pediré a los pasajeros que lo utilicen; aplicaré las medidas especiales que correspondan para niñas, niños, adolescentes y personas que requieran sistemas de retención.",
                    "Respetaré límites de velocidad, semáforos, señalamientos, indicaciones de agentes, preferencia peatonal y una distancia de seguridad adecuada.",
                    "No operaré el teléfono ni otros dispositivos mientras el vehículo esté en movimiento. Detendré la unidad en un lugar seguro cuando deba interactuar con la plataforma.",
                    "Portaré licencia vigente para la clase de vehículo, tarjeta de circulación vigente y póliza de seguro con cobertura de daños a terceros; exhibiré la documentación cuando la autoridad competente la solicite.",
                    "No transportaré más personas, peso o carga de la capacidad autorizada y aseguraré objetos, equipo y equipaje para evitar riesgos.",
                    "Mantendré en correcto funcionamiento faros, luces, direccionales, espejos, cinturones, claxon, frenos, llantas y demás sistemas de seguridad exigibles.",
                    "Conduciré libre de alcohol cuando resulte aplicable a transporte público y nunca conduciré bajo una condición o sustancia que impida hacerlo con seguridad.",
                    "En descompostura o accidente, protegeré la zona, alertaré a terceros, solicitaré ayuda, cumpliré las indicaciones de la autoridad y reportaré el incidente a Yavoi!.",
                ],
            ),
            (
                "Actualización y alcance",
                [
                    "Revisaré periódicamente la versión vigente de la ley, sus reformas y los reglamentos aplicables. La referencia integrada a la plataforma puede actualizarse sin sustituir la publicación oficial.",
                    "Reconozco que la autorización de Yavoi! no equivale a concesión, permiso, licencia o validación gubernamental y no elimina ninguna obligación frente a las autoridades.",
                    "Acepto que Operaciones solicite evidencias de vigencia o cumplimiento y que suspenda preventivamente mi disponibilidad cuando exista documentación vencida o un riesgo verificable.",
                ],
            ),
        ],
        reference=(
            "Ley de Vialidad y Tránsito para el Estado de Chihuahua. Publicación oficial del H. Congreso del Estado, última reforma indicada: POE 2026.08.08/No. 63. Artículos de referencia: 3, 33, 36, 41, 42, 48, 49, 50, 52, 70 y 75. Consulta: https://www.congresochihuahua2.gob.mx/biblioteca/leyes/archivosLeyes/117.pdf"
        ),
    )
    for source in (policy_path, traffic_path):
        (PUBLIC / source.name).write_bytes(source.read_bytes())


if __name__ == "__main__":
    main()
