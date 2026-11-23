"""Regenerate the case documents from src/cases.json.

Requires Python, reportlab and PyMuPDF. Fonts are supplied locally, never
downloaded or redistributed separately. This is an editorial build utility;
Netlify only needs the committed PDFs and the Node build.
"""
import argparse
import json
import os
from pathlib import Path
from xml.sax.saxutils import escape

import pymupdf
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, KeepTogether

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
body = ParagraphStyle('Body', fontName='Clinical', fontSize=10.4, leading=16.2, textColor=navy)
label_style = ParagraphStyle('Label', parent=body, fontName='ClinicalBold', fontSize=8.2, leading=12, textColor=blue)
small = ParagraphStyle('Small', parent=body, fontSize=7.8, leading=11.8, textColor=muted)
subtitle = ParagraphStyle('Subtitle', parent=body, fontSize=11, leading=16, textColor=blue)
title = ParagraphStyle('Title', parent=body, fontName='ClinicalBold', fontSize=21, leading=27)
tag = ParagraphStyle('Tag', parent=small, fontName='ClinicalBold', fontSize=7, leading=11, textColor=blue)
section_title = ParagraphStyle('SectionTitle', parent=body, fontName='ClinicalBold', fontSize=9.3, leading=14, textColor=navy)
meta = ParagraphStyle('Meta', parent=body, fontSize=8.5, leading=13)


def p(text, style=body):
    return Paragraph(escape(text), style)


def frame(canvas, document):
    canvas.saveState()
    w, h = document.pagesize
    canvas.setFillColor(navy)
    canvas.setFont('ClinicalBold', 12)
    canvas.drawString(17*mm, h-20*mm, 'iDRG')
    canvas.setFont('Clinical', 7)
    canvas.setFillColor(muted)
    canvas.drawString(33*mm, h-20*mm, 'LEARNING / CLINICAL CASE FILE')
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
    canvas.drawString(17*mm, 12.5*mm, 'DOKUMEN PEMBELAJARAN  /  ICS 2026')
    canvas.drawRightString(w-17*mm, 12.5*mm, f'{document.case_id}  /  HALAMAN {document.page}')
    canvas.restoreState()


def metadata(case):
    material = str(case['module'])
    rows = [[
        Paragraph('<font color="#7c899b" size="7">ID DOKUMEN</font><br/><b>'+case['id']+'</b>', meta),
        Paragraph('<font color="#7c899b" size="7">MATERI PELATIHAN</font><br/><b>Materi '+material+'</b>', meta),
        Paragraph('<font color="#7c899b" size="7">SUMBER DOKUMENTASI</font><br/><b>ICS 2026</b>', meta),
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


def record_row(index, label, text):
    label = label.replace(' · ', '<br/>')
    heading = Paragraph(escape(label).replace('&lt;br/&gt;', '<br/>'), label_style)
    row = Table([[heading, p(text)]], colWidths=[W*.255, W*.745], hAlign='LEFT')
    row.setStyle(TableStyle([
        ('BACKGROUND',(0,0),(0,0),light),
        ('BOX',(0,0),(-1,-1),.5,line),
        ('LINEAFTER',(0,0),(0,0),.5,line),
        ('VALIGN',(0,0),(-1,-1),'TOP'),
        ('LEFTPADDING',(0,0),(-1,-1),11),('RIGHTPADDING',(0,0),(-1,-1),11),
        ('TOPPADDING',(0,0),(-1,-1),12),('BOTTOMPADDING',(0,0),(-1,-1),12),
    ]))
    return KeepTogether(row)


def identity(case):
    text='Nama dan usia pasien: tidak dicantumkan dalam sumber. Tanggal masuk dan keluar: tidak dicantumkan dalam sumber.'
    return p(text,small)


def roman(number):
    return ['', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X'][number]


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
    document = SimpleDocTemplate(str(path), pagesize=(210*mm,297*mm),
        leftMargin=17*mm,rightMargin=17*mm,topMargin=33*mm,bottomMargin=24*mm,
        title=case['id']+' | '+case['title'], author='iDRG Learning',
        subject='Rekonstruksi berkas kasus dari materi ICS 2026')
    document.case_id = case['id']
    story = [p('BERKAS LATIHAN / '+('AUDIT CASEMIX' if audit else 'DOKUMENTASI KLINIS'),tag),
        Spacer(1,2*mm),p('LEMBAR KERJA CASEMIX' if audit else 'RESUME MEDIS',title),
        Spacer(1,1.5*mm),p(case['title'],subtitle),Spacer(1,6*mm),metadata(case),Spacer(1,6*mm)]
    if audit:
        for label,text in case['records']:
            story.extend([p(text),Spacer(1,6*mm)])
        story.extend([group_result(case),Spacer(1,6*mm)])
    else:
        story.extend([p('I. IDENTITAS BERKAS',section_title),Spacer(1,2*mm),identity(case),Spacer(1,5*mm)])
        for index,(label,text) in enumerate(case['records'],2):
            story.extend([KeepTogether([p(roman(index)+'. '+label.upper(),section_title),Spacer(1,2*mm),p(text),Spacer(1,4*mm)])])
    note = ('Baca kasus dan hasil grouping di atas, lalu jawab pertanyaan pada aplikasi latihan.' if audit else
        'Identitas pasien dan tanggal pelayanan tidak dicantumkan pada sumber. Hanya informasi klinis yang tersedia dalam materi yang ditampilkan.')
    story.extend([Spacer(1,3*mm),p('KELENGKAPAN DOKUMEN',tag),Spacer(1,1*mm),p(note,small),Spacer(1,2*mm),
        p('Berkas ini merupakan rekonstruksi untuk latihan, bukan salinan rekam medis pasien. Tidak ada rincian identitas, hasil pemeriksaan, atau tindakan yang ditambahkan di luar sumber.',small)])
    document.build(story,onFirstPage=frame,onLaterPages=frame)
    with pymupdf.open(path) as pdf:
        text=''.join(page.get_text() for page in pdf)
        assert len(pdf)<=2, (case['id'],len(pdf))
        assert case['id'] in text and 'KELENGKAPAN DOKUMEN' in text
        for page in pdf:
            for block in page.get_text('blocks'):
                assert block[0]>=40 and block[2]<560 and block[1]>20 and block[3]<820, (case['id'],block)
        print(case['id'],len(pdf),'page(s)',path.stat().st_size,'bytes')
