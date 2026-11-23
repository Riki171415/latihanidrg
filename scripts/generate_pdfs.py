"""Regenerate the case documents from src/cases.json.

Requires Python, reportlab and PyMuPDF. Fonts are supplied locally, never
downloaded or redistributed separately. This is an editorial build utility;
Netlify only needs the committed PDFs and the Node build.
"""
import argparse
import json
import os
import shutil
from pathlib import Path
from xml.sax.saxutils import escape

import pymupdf
from reportlab.lib import colors
from reportlab.lib.enums import TA_JUSTIFY, TA_LEFT
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, KeepTogether, PageBreak

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--font-dir', default=str(Path(os.environ.get('WINDIR', 'C:/Windows'))/'Fonts'))
args = parser.parse_args()
font_dir = Path(args.font_dir)
pdfmetrics.registerFont(TTFont('Clinical', str(font_dir/'arial.ttf')))
pdfmetrics.registerFont(TTFont('ClinicalBold', str(font_dir/'arialbd.ttf')))
pdfmetrics.registerFontFamily('Clinical', normal='Clinical', bold='ClinicalBold')

navy = colors.HexColor('#19365c')
blue = colors.HexColor('#375c8e')
muted = colors.HexColor('#7c899b')
line = colors.HexColor('#d8e0ea')
light = colors.HexColor('#f4f7fb')
white = colors.white
W = 176*mm
body = ParagraphStyle('Body', fontName='Clinical', fontSize=10, leading=14.6,
    textColor=colors.HexColor('#24303c'), alignment=TA_JUSTIFY,
    spaceAfter=1.8*mm, allowWidows=0, allowOrphans=0)
label_style = ParagraphStyle('Label', parent=body, fontName='ClinicalBold', fontSize=8.5, leading=12,
    textColor=blue, alignment=TA_LEFT)
small = ParagraphStyle('Small', parent=body, fontSize=8.2, leading=12.2, textColor=muted, alignment=TA_LEFT)
subtitle = ParagraphStyle('Subtitle', parent=body, fontSize=11, leading=16, textColor=blue, alignment=TA_LEFT)
title = ParagraphStyle('Title', parent=body, fontName='ClinicalBold', fontSize=22, leading=28, alignment=TA_LEFT)
tag = ParagraphStyle('Tag', parent=small, fontName='ClinicalBold', fontSize=7.5, leading=11, textColor=blue)
section_title = ParagraphStyle('SectionTitle', parent=body, fontName='ClinicalBold', fontSize=9.5, leading=14,
    textColor=navy, alignment=TA_LEFT, keepWithNext=True, spaceBefore=2.6*mm, spaceAfter=1.7*mm)
meta = ParagraphStyle('Meta', parent=body, fontSize=8.5, leading=13, alignment=TA_LEFT)
cell_body = ParagraphStyle('CellBody', parent=body, fontSize=10, leading=14.5, alignment=TA_LEFT, spaceAfter=0)
cell_header = ParagraphStyle('CellHeader', parent=label_style, fontSize=8.8, leading=13, spaceAfter=0, textColor=white)


def p(text, style=body):
    return Paragraph(escape(text).replace('\n','<br/>'), style)


def frame(canvas, document):
    canvas.saveState()
    w, h = document.pagesize
    canvas.setFillColor(navy)
    canvas.setFont('ClinicalBold', 12)
    canvas.drawString(17*mm, h-20*mm, 'iDRG')
    canvas.setFont('Clinical', 7)
    canvas.setFillColor(muted)
    canvas.drawString(33*mm, h-20*mm, 'BERKAS REKAM MEDIS')
    canvas.setFont('ClinicalBold', 8.5)
    canvas.setFillColor(blue)
    canvas.drawRightString(w-17*mm, h-20*mm, document.case_id)
    canvas.setStrokeColor(navy)
    canvas.setLineWidth(1.1)
    canvas.line(17*mm, h-26*mm, w-17*mm, h-26*mm)
    canvas.setStrokeColor(line)
    canvas.setLineWidth(.5)
    canvas.line(17*mm, 18*mm, w-17*mm, 18*mm)
    canvas.setFillColor(muted)
    canvas.setFont('Clinical', 7)
    canvas.drawString(17*mm, 12.5*mm, 'BERKAS KASUS / PELATIHAN iDRG')
    canvas.drawRightString(w-17*mm, 12.5*mm, f'{document.case_id}  /  HALAMAN {document.page}')
    canvas.restoreState()


def metadata(case):
    material = str(case.get('displayModule',case['module']))
    rows = [[
        Paragraph('<font color="#7c899b" size="7">ID DOKUMEN</font><br/><b>'+case.get('displayId',case['id'])+'</b>', meta),
        Paragraph('<font color="#7c899b" size="7">MATERI PELATIHAN</font><br/><b>Materi '+material+'</b>', meta),
        Paragraph('<font color="#7c899b" size="7">ACUAN PENGODEAN</font><br/><b>ICS 2026</b>', meta),
    ]]
    t = Table(rows, colWidths=[W*.28, W*.34, W*.38], hAlign='LEFT')
    t.setStyle(TableStyle([
        ('BACKGROUND',(0,0),(-1,-1),light),
        ('BOX',(0,0),(-1,-1),.5,line),
        ('LINEAFTER',(0,0),(1,0),.5,line),
        ('VALIGN',(0,0),(-1,-1),'TOP'),
        ('LEFTPADDING',(0,0),(-1,-1),11),('RIGHTPADDING',(0,0),(-1,-1),11),
        ('TOPPADDING',(0,0),(-1,-1),10),('BOTTOMPADDING',(0,0),(-1,-1),10),
    ]))
    return t


def entries(value):
    if not value: return p('Tidak tercantum.',small)
    values=value if isinstance(value,list) else [value]
    return [p((str(i)+'. ' if len(values)>1 else '')+text,cell_body) for i,text in enumerate(values,1)]


def paired_fields(left_heading,right_heading,left_value,right_value):
    table=Table([
        [p(left_heading,cell_header),p(right_heading,cell_header)],
        [entries(left_value),entries(right_value)]],
        colWidths=[W*.5,W*.5],repeatRows=1,hAlign='LEFT')
    table.setStyle(TableStyle([
        ('BACKGROUND',(0,0),(-1,0),navy),
        ('BACKGROUND',(0,1),(-1,1),colors.HexColor('#fbfcfe')),
        ('BOX',(0,0),(-1,-1),.5,line),
        ('LINEAFTER',(0,0),(0,-1),.5,line),
        ('VALIGN',(0,0),(-1,-1),'TOP'),
        ('LEFTPADDING',(0,0),(-1,-1),11),('RIGHTPADDING',(0,0),(-1,-1),11),
        ('TOPPADDING',(0,0),(-1,0),7),('BOTTOMPADDING',(0,0),(-1,0),7),
        ('TOPPADDING',(0,1),(-1,-1),11),('BOTTOMPADDING',(0,1),(-1,-1),13),
    ]))
    return table


def narrative(text):
    blocks=[]
    for value in text.split('\n'):
        value=value.strip()
        if not value:continue
        # Start a separate paragraph for each field instead of forced line
        # breaks within one justified paragraph; this prevents wide word gaps.
        label,separator,rest=value.partition(':')
        if separator and len(label)<48:
            blocks.append(Paragraph('<b>'+escape(label)+':</b> '+escape(rest.strip()),body))
        else:blocks.append(p(value))
    return blocks


def roman(number):
    result=''
    for value,symbol in [(10,'X'),(9,'IX'),(5,'V'),(4,'IV'),(1,'I')]:
        while number>=value:
            result+=symbol
            number-=value
    return result


def group_result(case):
    value=Paragraph(escape(case['groupCode']),ParagraphStyle('GroupCode',parent=title,fontSize=28,leading=35))
    result=Table([[p('HASIL GROUPING',label_style),value]],colWidths=[W*.39,W*.61])
    result.setStyle(TableStyle([
        ('BACKGROUND',(0,0),(-1,-1),light),('BOX',(0,0),(-1,-1),.6,line),
        ('VALIGN',(0,0),(-1,-1),'MIDDLE'),('LEFTPADDING',(0,0),(-1,-1),15),
        ('TOPPADDING',(0,0),(-1,-1),14),('BOTTOMPADDING',(0,0),(-1,-1),14),
    ]))
    return result


cases = json.loads((ROOT/'src/cases.json').read_text(encoding='utf-8'))
for case in cases:
    audit = case['id']=='M2-01'
    path = ROOT/'public'/case['pdf']
    path.parent.mkdir(parents=True,exist_ok=True)
    document = SimpleDocTemplate(str(path), pagesize=(210*mm,297*mm),
        leftMargin=17*mm,rightMargin=17*mm,topMargin=33*mm,bottomMargin=24*mm,
        title=case.get('displayId',case['id'])+' | '+case['title'], author='iDRG Learning',
        subject='Resume medis dan laporan tindakan')
    document.case_id = case.get('displayId',case['id'])
    story = [p('DOKUMEN CASEMIX' if audit else 'DOKUMEN REKAM MEDIS',tag),
        Spacer(1,2*mm),p('LEMBAR KERJA CASEMIX' if audit else 'RESUME MEDIS',title),
        Spacer(1,1.5*mm),p(case['title'],subtitle),Spacer(1,4*mm),metadata(case),Spacer(1,3*mm)]
    if audit:
        for label,text in case['records']:
            story.extend([p(text),Spacer(1,6*mm)])
        story.extend([group_result(case),Spacer(1,6*mm)])
    else:
        current_episode=None
        episode_key=''
        index=0
        for label,text in case['records']:
            if ' / ' in label and label.startswith('Episode '):
                episode,label=label.split(' / ',1)
                episode_key=episode.split()[-1]
                if episode!=current_episode:
                    if current_episode is not None: story.append(PageBreak())
                    story.extend([p('PASIEN '+episode_key,subtitle)])
                    index=0
                    current_episode=episode
            index+=1
            fields=case['chartFields'][episode_key]
            story.append(p(roman(index)+'. '+label.upper(),section_title))
            if label=='Diagnosis dokter':
                diagnosis_block=[paired_fields('DIAGNOSIS UTAMA','DIAGNOSIS SEKUNDER',
                    fields['diagnosisPrimary'],fields['diagnosisSecondary']),Spacer(1,2.5*mm)]
                if fields.get('diagnosisNote'): diagnosis_block.extend(narrative(fields['diagnosisNote']))
                story.append(KeepTogether(diagnosis_block))
            elif label=='Laporan tindakan':
                story.extend([paired_fields('PROSEDUR UTAMA','PROSEDUR SEKUNDER',
                    fields['procedurePrimary'],fields['procedureSecondary']),Spacer(1,2.5*mm)])
                if fields.get('procedureNote'):story.append(p(fields['procedureNote'],small))
                story.extend(narrative(text))
            else:story.extend(narrative(text))
    document.build(story,onFirstPage=frame,onLaterPages=frame)
    # Older bookmarks continue to resolve to the latest clinical document.
    alias=ROOT/'public/cases'/(case['id']+'.pdf')
    if alias!=path: shutil.copyfile(path,alias)
    with pymupdf.open(path) as pdf:
        text=''.join(page.get_text() for page in pdf)
        assert 'simulasi' not in text.lower()
        assert len(pdf)<=12, (case['id'],len(pdf))
        assert case.get('displayId',case['id']) in text and ('RESUME MEDIS' in text or 'LEMBAR KERJA CASEMIX' in text)
        if not audit:
            for heading in ['DIAGNOSIS UTAMA','DIAGNOSIS SEKUNDER','PROSEDUR UTAMA','PROSEDUR SEKUNDER']:
                assert text.count(heading)>=len(case['chartFields']),(case['id'],heading)
        for page in pdf:
            for block in page.get_text('blocks'):
                assert block[0]>=40 and block[2]<560 and block[1]>20 and block[3]<820, (case['id'],block)
        print(case['id'],len(pdf),'page(s)',path.stat().st_size,'bytes')
