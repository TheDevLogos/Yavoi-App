from pathlib import Path
from shutil import copy2

from PIL import Image as PILImage
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_RIGHT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    HRFlowable,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ROOT / "public" / "documents"
OUTPUT = ROOT / "output" / "pdf"
TMP = ROOT / "tmp" / "pdfs"
LOGO_SOURCE = ROOT / "public" / "assets" / "yavoi-logo.png"
POLICY_VERSION = "YV-POL-CON-2026.09.12"
TRAFFIC_VERSION = "YV-VIAL-POE-2026.08.08-63"
LAW_URL = "https://www.congresochihuahua2.gob.mx/biblioteca/leyes/archivosLeyes/117.pdf"

NAVY = colors.HexColor("#071D33")
ORANGE = colors.HexColor("#FF6A0A")
MUTED = colors.HexColor("#64758A")
PALE = colors.HexColor("#F3F6F9")
LINE = colors.HexColor("#DCE4EC")

for directory in (PUBLIC, OUTPUT, TMP):
    directory.mkdir(parents=True, exist_ok=True)

pdfmetrics.registerFont(TTFont("YavoiSans", "/System/Library/Fonts/Supplemental/Arial.ttf"))
pdfmetrics.registerFont(TTFont("YavoiSans-Bold", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"))

logo = PILImage.open(LOGO_SOURCE).convert("RGBA")
alpha_box = logo.getchannel("A").getbbox()
if alpha_box:
    logo = logo.crop(alpha_box)
cropped_logo = TMP / "yavoi-logo-cropped.png"
logo.save(cropped_logo)

styles = getSampleStyleSheet()
styles.add(ParagraphStyle(name="DocTitle", fontName="YavoiSans-Bold", fontSize=19, leading=23, textColor=NAVY, spaceAfter=10))
styles.add(ParagraphStyle(name="Intro", fontName="YavoiSans", fontSize=9.4, leading=14, textColor=NAVY, alignment=TA_JUSTIFY, spaceAfter=8))
styles.add(ParagraphStyle(name="Section", fontName="YavoiSans-Bold", fontSize=12, leading=15, textColor=ORANGE, spaceBefore=10, spaceAfter=6))
styles.add(ParagraphStyle(name="Item", fontName="YavoiSans", fontSize=9.1, leading=13.2, textColor=NAVY, alignment=TA_JUSTIFY, leftIndent=14, firstLineIndent=-14, spaceAfter=5))
styles.add(ParagraphStyle(name="Small", fontName="YavoiSans", fontSize=7.8, leading=10.5, textColor=MUTED))
styles.add(ParagraphStyle(name="SmallCenter", fontName="YavoiSans", fontSize=7.8, leading=10.5, textColor=MUTED, alignment=TA_CENTER))
styles.add(ParagraphStyle(name="Legal", fontName="YavoiSans", fontSize=8.1, leading=11.5, textColor=MUTED, alignment=TA_JUSTIFY))
styles.add(ParagraphStyle(name="Declaration", fontName="YavoiSans", fontSize=9.5, leading=14.2, textColor=NAVY, alignment=TA_JUSTIFY, spaceAfter=10))
styles.add(ParagraphStyle(name="Field", fontName="YavoiSans", fontSize=8.5, leading=11, textColor=MUTED))


def header_footer(canvas, doc, version):
    canvas.saveState()
    width, height = letter
    canvas.setFillColor(colors.white)
    canvas.rect(0, height - 74, width, 74, stroke=0, fill=1)
    canvas.drawImage(str(cropped_logo), doc.leftMargin, height - 62, width=98, height=48, preserveAspectRatio=True, anchor="w", mask="auto")
    canvas.setFont("YavoiSans-Bold", 8)
    canvas.setFillColor(NAVY)
    canvas.drawRightString(width - doc.rightMargin, height - 30, "EXPEDIENTE DE CONDUCTOR")
    canvas.setFont("YavoiSans", 6.8)
    canvas.setFillColor(MUTED)
    canvas.drawRightString(width - doc.rightMargin, height - 43, version)
    canvas.setStrokeColor(ORANGE)
    canvas.setLineWidth(2)
    canvas.line(doc.leftMargin, height - 70, width - doc.rightMargin, height - 70)
    canvas.setStrokeColor(ORANGE)
    canvas.setLineWidth(1.7)
    canvas.line(doc.leftMargin, 31, doc.leftMargin + 92, 31)
    canvas.setFont("YavoiSans", 7)
    canvas.setFillColor(MUTED)
    canvas.drawString(doc.leftMargin, 19, "Yavoi! · Tu raite, al instante · Delicias, Chihuahua")
    canvas.drawRightString(width - doc.rightMargin, 19, f"Página {doc.page}")
    canvas.restoreState()


def item(number, text):
    return Paragraph(f"<b>{number}.</b> {text}", styles["Item"])


def section(title, items):
    flow = [Paragraph(title, styles["Section"])]
    flow.extend(item(index, text) for index, text in enumerate(items, 1))
    return flow


def reference_box(title, body):
    table = Table(
        [[Paragraph(title, styles["Small"]), Paragraph(body, styles["Legal"])]],
        colWidths=[42 * mm, 126 * mm],
        hAlign="LEFT",
    )
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), PALE),
        ("BOX", (0, 0), (-1, -1), 0.6, LINE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
    ]))
    return table


def signature_page(version, acknowledgements):
    flow = [
        Paragraph("Declaración, aceptación y firma", styles["DocTitle"]),
        Paragraph(
            "Declaro que leí el documento completo, comprendí sus alcances y tuve oportunidad de formular preguntas. "
            "Confirmo que los datos y documentos proporcionados son verdaderos, que conservaré una copia y que cargaré "
            "en Yavoi! todas las páginas de esta carta, completas, legibles y firmadas.",
            styles["Declaration"],
        ),
    ]
    for text in acknowledgements:
        flow.append(Paragraph(f"□ {text}", styles["Declaration"]))
    flow.extend([
        Spacer(1, 10),
        reference_box("VERSIÓN ACEPTADA", f"{version}<br/>Fecha de actualización de la plantilla: 12 de septiembre de 2026."),
        Spacer(1, 26),
    ])
    fields = [
        ("Nombre completo", ""),
        ("CURP", ""),
        ("Número de licencia", ""),
        ("Identificador de cuenta Yavoi!", ""),
        ("Lugar y fecha", ""),
    ]
    for label, _ in fields:
        flow.extend([Paragraph(label, styles["Field"]), Spacer(1, 22), HRFlowable(width="100%", thickness=0.7, color=MUTED), Spacer(1, 12)])
    flow.extend([
        Spacer(1, 22),
        HRFlowable(width="58%", thickness=0.8, color=NAVY, hAlign="CENTER"),
        Paragraph("Firma autógrafa de la persona conductora", styles["SmallCenter"]),
        Spacer(1, 20),
        Paragraph(
            "La recepción de esta carta por Yavoi! no sustituye permisos, licencias, pólizas, contratos ni obligaciones "
            "establecidas por las autoridades competentes.",
            styles["Legal"],
        ),
    ])
    return flow


def build_pdf(filename, title, version, subject, story):
    target = PUBLIC / filename
    doc = SimpleDocTemplate(
        str(target), pagesize=letter, rightMargin=50, leftMargin=50, topMargin=88, bottomMargin=48,
        title=title, author="Yavoi!", subject=subject,
    )
    doc.build(
        story,
        onFirstPage=lambda c, d: header_footer(c, d, version),
        onLaterPages=lambda c, d: header_footer(c, d, version),
    )
    copy2(target, OUTPUT / filename)


policy_story = [
    Paragraph("Carta de compromiso y aceptación de políticas Yavoi!", styles["DocTitle"]),
    Paragraph(
        "A quien corresponda: por medio de la presente, la persona conductora que firma solicita integrar o actualizar "
        "su expediente en Yavoi! y acepta los compromisos siguientes como condición para conservar su autorización y "
        "participar en la operación de la plataforma.",
        styles["Intro"],
    ),
]
policy_story += section("Identidad, expediente y unidad", [
    "Proporcionaré información verdadera, actual y comprobable. Mi cuenta, contraseña, sesión, fotografía y documentos son personales; no los prestaré, compartiré ni transferiré.",
    "Mantendré vigentes la licencia, tarjeta de circulación, póliza de seguro y permisos que correspondan. La unidad, placas, categoría, color y conductor deberán coincidir con lo autorizado por Operaciones.",
    "Informaré cualquier cambio de datos, vehículo o documentación. Comprendo que, al completarse, mi perfil queda protegido y sólo podrá modificarse durante una autorización temporal de Operaciones, con registro en Auditoría.",
    "Mantendré la unidad limpia, segura y en condiciones mecánicas, eléctricas y sanitarias adecuadas para la categoría ofrecida, incluyendo los elementos requeridos para servicios de accesibilidad o carga cuando apliquen.",
])
policy_story += section("Disponibilidad, asignación y ubicación", [
    "Me marcaré disponible únicamente cuando pueda recibir y realizar servicios. Mantendré abierta la plataforma y permitiré la ubicación necesaria para renovar mi presencia mientras esté conectado.",
    "Revisaré antes de aceptar el origen, destino, categoría, número de personas, carga, accesibilidad, forma de pago, distancia, tiempo e indicaciones mostradas. Podré aceptar o rechazar sin manipular el sistema ni discriminar a la persona usuaria.",
    "No alteraré, simularé ni ocultaré mi ubicación, orientación, recorridos, tiempos o estados. La señal GPS podrá utilizarse para asignación, seguimiento del acercamiento, guía de ruta, seguridad, soporte, conciliación y Auditoría.",
    "Seguiré rutas seguras y razonables. La guía de navegación es auxiliar: atenderé cierres, señalización, condiciones reales y órdenes de la autoridad; nunca interactuaré con la pantalla mientras el vehículo esté en movimiento.",
])
policy_story += section("Atención y desarrollo del viaje", [
    "Trataré a todas las personas con respeto y dignidad, sin violencia, hostigamiento, represalias ni conductas discriminatorias. Respetaré solicitudes de conductora mujer sujetas a disponibilidad y necesidades de personas con discapacidad.",
    "Confirmaré de manera segura el punto de encuentro. Usaré la mensajería del viaje sólo para referencias o datos necesarios y no conservaré ni utilizaré datos personales después del servicio.",
    "Registraré fielmente los estados: llegada, verificación del PIN, inicio, trayecto y finalización. No iniciaré sin la persona correcta ni compartiré el PIN; no finalizaré antes de llegar al destino acordado.",
    "Respetaré la capacidad de pasajeros y carga. Podré rechazar o detener el servicio cuando exista exceso de capacidad, riesgo, violencia, consumo de sustancias, daño a la unidad o incumplimiento grave, procurando un descenso seguro y reportando el hecho.",
    "Ante peligro inmediato utilizaré los medios de emergencia y contactaré al 911. Reportaré accidentes, amenazas, fallas, objetos olvidados, fraude y cualquier incidente mediante las herramientas de Yavoi! tan pronto sea seguro hacerlo.",
])
policy_story.append(PageBreak())
policy_story += section("Tarifas, pagos, propinas y cancelaciones", [
    "Cobraré exclusivamente el total confirmado por la plataforma. En efectivo registraré la recepción y entregaré el cambio indicado; en pago electrónico esperaré la confirmación del sistema. No solicitaré cargos fuera de la aplicación.",
    "Las propinas son voluntarias y pertenecen al conductor conforme al registro aplicable. No presionaré, condicionaré el servicio ni alteraré una valoración para obtenerlas.",
    "Cumpliré la modalidad comercial asignada por Operaciones: aportación semanal o comisión por viaje. Cuando corresponda, transferiré y cargaré oportunamente el comprobante de comisiones de viajes en efectivo; los porcentajes electrónicos se conciliarán según la configuración vigente del viaje.",
    "Respetaré el flujo de cancelación, los periodos de gracia, avisos, cuotas y reembolsos calculados por el servidor. No presionaré al usuario para cancelar ni acordaré cancelaciones o pagos por fuera de Yavoi!.",
])
policy_story += section("Calificaciones, recompensas y publicidad", [
    "Evaluaré al usuario con honestidad y fundamentos relacionados con el servicio. No intercambiaré, compraré ni manipularé calificaciones, viajes, puntos, cupones o códigos de recompensa.",
    "Los beneficios dependen de actividad, ingresos, calificación, incidentes, inventario y condiciones del proveedor. Usaré cada cupón individual sólo como se indique y no duplicaré, alteraré ni transferiré códigos cuando sean personales.",
    "Participaré en convenios de publicidad únicamente si los acepto y Operaciones los autoriza. No colocaré material que afecte visibilidad, seguridad, limpieza, identificación o cumplimiento legal de la unidad.",
])
policy_story += section("Privacidad, seguridad digital y trazabilidad", [
    "Usaré la información de pasajeros exclusivamente para el servicio, seguridad o requerimiento legítimo de autoridad. No tomaré capturas, fotografías, grabaciones ni compartiré datos salvo causa autorizada y legal.",
    "Protegeré mi acceso, cerraré sesiones en equipos ajenos y reportaré pérdida, acceso sospechoso o suplantación. No intentaré evadir controles de autenticación, roles, perfil, pagos o disponibilidad.",
    "Acepto que viajes, ubicaciones operativas, mensajes, pagos, cancelaciones, valoraciones, reportes, documentos y acciones administrativas se conserven con controles de acceso para operación, seguridad, aclaraciones y obligaciones aplicables.",
])
policy_story += section("Cumplimiento y continuidad", [
    "Operaciones podrá solicitar evidencias, pausar la disponibilidad o desactivar preventivamente la cuenta por documentación vencida, riesgos, fraude o incumplimiento verificable, conservando trazabilidad y mecanismos de revisión.",
    "Esta carta complementa los Términos de Servicio, el aviso de privacidad, reglas de seguridad y configuración comercial vigentes. Las actualizaciones materiales requerirán una nueva aceptación cuando Yavoi! así lo determine.",
    "Entiendo que Yavoi! facilita la operación tecnológica y no sustituye mi responsabilidad profesional, civil, administrativa, fiscal, laboral o penal, ni las obligaciones derivadas de permisos y leyes aplicables.",
])
policy_story.append(PageBreak())
policy_story += signature_page(POLICY_VERSION, [
    "Acepto las políticas de identidad, seguridad, ubicación, atención, pagos, cancelaciones y protección de datos descritas en esta carta.",
    "Acepto la modalidad comercial configurada en mi perfil y la obligación de revisar cada viaje antes de aceptarlo.",
    "Comprendo que una infracción legal o un riesgo grave puede causar la suspensión preventiva de mi disponibilidad.",
])

traffic_story = [
    Paragraph("Carta de compromiso y aceptación de obligaciones viales", styles["DocTitle"]),
    Paragraph(
        "A quien corresponda: declaro conocer que toda persona que utiliza las vías públicas en el Estado de Chihuahua "
        "debe cumplir la Ley de Vialidad y Tránsito, sus reglamentos y las disposiciones municipales, estatales y federales "
        "aplicables a su vehículo y modalidad de servicio.",
        styles["Intro"],
    ),
    reference_box(
        "REFERENCIA NORMATIVA",
        "Ley de Vialidad y Tránsito para el Estado de Chihuahua. Última reforma indicada por el H. Congreso del Estado: "
        "POE 2026.08.08/No. 63. Referencias principales: artículos 3, 33, 34, 36, 41, 42, 42 Bis, 48, 49, 50, 52, 70, 75, 76 y 77. "
        f'<link href="{LAW_URL}" color="#C9570C">Consultar publicación oficial</link>.',
    ),
]
traffic_story += section("Documentación e identificación vehicular", [
    "Portaré licencia vigente adecuada a la clase de vehículo, tarjeta de circulación, placas y póliza de seguro vigente con cobertura de daños a terceros, además de los permisos o autorizaciones que resulten exigibles.",
    "Las placas y la tarjeta de circulación deberán corresponder al vehículo autorizado. No usaré medios de identificación expedidos para otra unidad y notificaré cualquier cambio de propiedad, posesión o registro.",
    "Reconozco que la licencia digital admitida por la autoridad funciona como accesorio de una licencia física vigente y no elimina los requisitos aplicables a su expedición, clase o exhibición.",
    "Presentaré la documentación a la autoridad competente cuando sea legalmente requerida y atenderé las revisiones físicas, mecánicas, eléctricas o documentales procedentes.",
])
traffic_story += section("Condiciones de la unidad, capacidad y visibilidad", [
    "Mantendré en correcto funcionamiento faros, luces traseras, direccionales, espejos, cinturones, claxon, frenos, llantas y demás sistemas de seguridad exigibles.",
    "Mantendré parabrisas, cristales, espejos y placas visibles y sin obstáculos. Cualquier material de publicidad será autorizado y colocado sin reducir visibilidad ni identificación.",
    "Respetaré peso, dimensiones, número de plazas y capacidad. Aseguraré equipaje, mercancía, mesas, equipo o cualquier carga para impedir desplazamientos y riesgos.",
    "No recogeré ni permitiré ascenso o descenso con la unidad en movimiento. Procuraré detenerme en un lugar permitido y seguro, cercano a la banqueta y sin bloquear rampas, cruces, paradas, accesos o zonas reservadas.",
])
traffic_story += section("Conducción segura y protección de ocupantes", [
    "Usaré el cinturón de seguridad y pediré a todas las personas pasajeras que lo utilicen durante el recorrido.",
    "Transportaré a niñas, niños, adolescentes de estatura menor a 1.35 metros o personas cuya constitución física lo requiera en una silla especial que cumpla la Norma Oficial Mexicana aplicable, asegurada en el asiento posterior.",
    "No conduciré bajo el influjo de alcohol, drogas, sustancias psicotrópicas, medicamentos incapacitantes, fatiga peligrosa ni condición que reduzca mi capacidad. Cumpliré el estándar de cero alcohol cuando legalmente corresponda a transporte público.",
    "No operaré ni accionaré teléfonos, navegación u otros dispositivos mientras el vehículo esté en movimiento. Antes de aceptar, rechazar, mensajear o cambiar un estado en Yavoi!, detendré la unidad en un lugar seguro.",
])
traffic_story.append(PageBreak())
traffic_story += section("Circulación, peatones y distancia", [
    "Respetaré límites de velocidad, semáforos, señalamientos, indicaciones de agentes y personal autorizado en zonas escolares.",
    "Disminuiré la velocidad o me detendré para dar preferencia peatonal y extremaré precauciones ante personas con discapacidad, niñas, niños, ciclistas y motociclistas.",
    "Conservaré una distancia que permita detenerme oportunamente considerando velocidad, clima, estado de la vía, tránsito, carga y condiciones de la unidad; nunca será inferior a las dimensiones del vehículo que conduzco cuando resulte aplicable.",
    "Facilitaré el paso de vehículos de emergencia y no los seguiré ni obstruiré. No estacionaré en sitios prohibidos, rampas, áreas de discapacidad, doble fila, cruces, banquetas, puentes o zonas de visibilidad reducida.",
])
traffic_story += section("Accidentes, averías y emergencias", [
    "En caso de avería o accidente, detendré la marcha, protegeré a las personas y colocaré señalamiento preventivo a una distancia no menor de treinta metros cuando corresponda, sin exponerme a un riesgo mayor.",
    "Solicitaré asistencia, primeros auxilios y autoridad competente; permaneceré o actuaré conforme a la ley y no alteraré injustificadamente la escena.",
    "Reportaré el incidente a Yavoi! cuando sea seguro, aportaré información verdadera y cooperaré con la aseguradora, Operaciones y autoridades, preservando datos personales y evidencia.",
])
traffic_story += section("Alcance de la aceptación", [
    "Revisaré periódicamente la versión oficial de la ley, reformas, reglamentos y disposiciones municipales aplicables. La referencia de Yavoi! es informativa y no sustituye la publicación oficial ni asesoría jurídica.",
    "La autorización de Yavoi! no equivale a concesión, permiso, licencia, registro o validación gubernamental y no elimina obligaciones frente a autoridades, pasajeros, terceros, aseguradoras o propietarios.",
    "Acepto que Operaciones solicite evidencia de vigencia o cumplimiento y suspenda preventivamente mi disponibilidad cuando exista documentación vencida, discordancia vehicular o riesgo verificable.",
])
traffic_story.append(PageBreak())
traffic_story += signature_page(TRAFFIC_VERSION, [
    "Leí la referencia normativa oficial y acepto cumplir la legislación y reglamentos aplicables a mi conducción.",
    "Reconozco las reformas de agosto de 2026 sobre identificación vehicular, sistemas de retención, teléfono y licencia digital.",
    "Comprendo que debo detener la unidad de forma segura antes de interactuar manualmente con Yavoi!.",
])

build_pdf(
    "carta-compromiso-politicas-yavoi.pdf",
    "Carta de compromiso y aceptación de políticas Yavoi!",
    POLICY_VERSION,
    "Expediente de conductor",
    policy_story,
)
build_pdf(
    "carta-aceptacion-vialidad-chihuahua.pdf",
    "Carta de compromiso y aceptación de obligaciones viales",
    TRAFFIC_VERSION,
    "Expediente de conductor",
    traffic_story,
)
print("Generated two Yavoi! driver letters.")
